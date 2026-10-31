import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'ble_models.dart';
import 'heart_rate_sample.dart';
import 'heart_rate_source.dart';
import 'notify_recovery_policy.dart';
import 'scan_tail.dart';

/// Android reference transport. flutter_blue_plus is intentionally pinned in
/// pubspec.yaml. Background execution is owned by native code, not this plugin.
///
/// 本类只负责「一条链路」的建立与拆除，并把断连事实如实上报（phase + 日志）。
/// 是否重连由 `HeartRateService` 的重连监督器决定。
final class FlutterBluePlusSource implements HeartRateSource {
  FlutterBluePlusSource({AppLogger? logger})
    : _log = logger ?? AppLogger.instance {
    // 原生 GATT 日志带上 133 之类的系统错误码，是断连复现时最关键的一条证据。
    _nativeLogSubscription = FlutterBluePlus.logs.listen(
      (message) => _log.debug('fbp', message),
      onError: (Object error) => _log.warn(
        'fbp',
        'native log stream failed: $error',
        code: 'fbp_log_error',
      ),
    );
  }

  static final _hrsService = Guid('0000180d-0000-1000-8000-00805f9b34fb');
  static final _hrsMeasurement = Guid('00002a37-0000-1000-8000-00805f9b34fb');
  final AppLogger _log;
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();
  final _decoder = const HrsDecoder();
  final _devices = <String, BluetoothDevice>{};
  final _rssiById = <String, int>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<String>? _nativeLogSubscription;
  BluetoothDevice? _connected;
  BleSnapshot _snapshot = const BleSnapshot();
  bool _disposed = false;

  /// 只有见过 `connected` 之后的 `disconnected` 才算掉线。
  /// `connectionState` 订阅会先吐一个当前缓存值（通常就是 disconnected），
  /// 不区分就会把「还没连上」误判成「刚掉线」，进而触发无谓的重连风暴。
  bool _linkUp = false;

  /// 上一次观测到的链路状态，用于只记录真实的状态转变（初始值不算）。
  BluetoothConnectionState? _lastLinkState;

  /// 每次连接建立后第一条心率样本记一次 info：只要这一行出现，
  /// 就能证明数据流是活的，不必依赖 debug 级别的逐包日志。
  bool _firstSampleLogged = false;

  /// Android Services Changed（0x2A05）/ GATT 缓存失效后 CCCD 会丢，
  /// 通知会**无声无息地停**，而链路还在。必须能重订阅。
  StreamSubscription<void>? _servicesResetSubscription;

  final _notifyRecovery = const NotifyRecoveryPolicy();
  final _resubscribeTimes = <DateTime>[];

  /// services_reset 与 notify_closed 可能同时触发；并发重订阅会留下孤儿监听
  /// （同一份通知被计两次），所以串行化。
  bool _resubscribing = false;

  /// 扫描轮次。扫描收尾（`Future.delayed(timeout)` 之后）如果这一轮已经被
  /// 新的扫描或连接流程接管，就绝不能再往 snapshot 上写 phase。
  ///
  /// 这一条是 2026-10-29 现场日志实锤的：用户在扫描还没结束时点了连接，
  /// 10 秒后扫描收尾把 `subscribed` 覆写成 `idle`，界面显示"空闲"而链路上
  /// 心率通知仍在持续送达，用户看到的就是"它自己断开了"。
  int _scanEpoch = 0;

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<BleSnapshot> get snapshots => _snapshots.stream;

  void _emit(BleSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    _snapshots.add(next);
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final epoch = ++_scanEpoch;
    if (_connected?.isConnected ?? false) {
      // 扫描与连接抢射频是掉线的经典诱因，先留证据再继续。
      _log.warn(
        'ble',
        'scan started while link is up',
        deviceId: _connected?.remoteId.str,
        code: 'scan_while_connected',
      );
    }
    _adapterSubscription ??= FlutterBluePlus.adapterState.listen((state) {
      _emit(_snapshot.copyWith(adapterState: state.name));
    });
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.adapterOff));
      throw StateError('BLE adapter unavailable');
    }
    _devices.clear();
    _rssiById.clear();
    _emit(
      _snapshot.copyWith(
        phase: BleConnectionPhase.scanning,
        devices: const [],
        clearError: true,
      ),
    );
    late final StreamSubscription<List<ScanResult>> scanSubscription;
    scanSubscription = FlutterBluePlus.scanResults.listen(
      (results) {
        for (final result in results) {
          final serviceUuids = result.advertisementData.serviceUuids;
          if (serviceUuids.contains(_hrsService)) {
            _devices[result.device.remoteId.str] = result.device;
            _rssiById[result.device.remoteId.str] = result.rssi;
          }
        }
        final infos = _devices.entries.map((entry) {
          return BleDeviceInfo(
            id: entry.key,
            name: entry.value.platformName,
            rssi: _rssiById[entry.key] ?? -127,
          );
        }).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
        _emit(_snapshot.copyWith(devices: infos));
      },
      onError: (Object error, StackTrace stack) {
        _log.error('ble', 'Scan failed: $error', null, error, stack);
      },
    );
    _subscriptions.add(scanSubscription);
    await FlutterBluePlus.startScan(
      withServices: [_hrsService],
      timeout: timeout,
    );
    await Future<void>.delayed(timeout);
    await scanSubscription.cancel();
    _subscriptions.remove(scanSubscription);
    final next = scanTailPhase(
      superseded: epoch != _scanEpoch,
      linkIsUp: _connected?.isConnected ?? false,
    );
    if (next == null) {
      // 这一轮扫描已被连接流程或新一轮扫描接管，收尾不得改动 phase。
      _log.debug(
        'ble',
        'stale scan tail ignored epoch=$epoch',
        code: 'scan_tail_ignored',
      );
      return;
    }
    _emit(_snapshot.copyWith(phase: next));
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration timeout = AppConfig.connectTimeout,
  }) async {
    final device = _devices[deviceId];
    if (device == null) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Scan first');
    }
    // 扫描与连接并发在部分 Android 协议栈上会互相干扰（扫描占空比高时
    // 连接更容易被踢）。连接前先收掉扫描，别让两件事抢射频。
    await FlutterBluePlus.stopScan();
    await disconnect();
    _resubscribeTimes.clear();
    _connected = device;
    // 先挂监听再发起连接：connect() 期间或刚返回时的掉线事件才不会漏。
    _watchConnectionState(device);
    _emit(
      _snapshot.copyWith(
        phase: BleConnectionPhase.connecting,
        connectedDeviceId: deviceId,
        clearError: true,
      ),
    );
    _log.info(
      'ble',
      'connect start timeout=${timeout.inSeconds}s',
      deviceId: deviceId,
      code: 'connect_start',
    );
    // stage 用来在日志里指明失败发生在哪一步；GATT 133 多出现在
    // discover 与 subscribe，二分不开就只能靠现场日志猜。
    var stage = 'connect';
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: timeout,
        autoConnect: false,
      );
      if (!device.isConnected) {
        _log.warn(
          'ble',
          'connect returned without GATT link',
          deviceId: deviceId,
          code: 'gatt_not_connected',
        );
        throw StateError('GATT not connected after connect()');
      }
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.discovering));
      stage = 'subscribe';
      await _subscribeNotifications(device, deviceId);
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.subscribed));
      _log.info(
        'ble',
        'HRS notifications subscribed',
        deviceId: deviceId,
        code: 'hrs_subscribed',
      );
    } catch (error, stack) {
      _log.error('ble', 'connect failed stage=$stage', deviceId, error, stack);
      rethrow;
    }
  }

  /// discover 服务 + 打开 0x2A37 通知 + 挂监听。首次连接与"只重订阅"共用，
  /// 保证两条路径行为一致（重订阅也必须重新 discover：Services Changed 之后
  /// 旧的 characteristic 对象已经失效）。
  Future<void> _subscribeNotifications(
    BluetoothDevice device,
    String deviceId,
  ) async {
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    final services = await device.discoverServices();
    BluetoothCharacteristic? measurement;
    for (final service in services) {
      if (service.uuid == _hrsService) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _hrsMeasurement) {
            measurement = characteristic;
          }
        }
      }
    }
    if (measurement == null) throw StateError('HRS 0x2A37 not found');
    await measurement.setNotifyValue(true);
    if (!measurement.isNotifying) {
      // CCCD 缓存有时不完整，不能据此判定订阅失败，只留痕。
      _log.warn(
        'ble',
        '0x2A37 notify not reflected in CCCD cache',
        deviceId: deviceId,
        code: 'notify_unverified',
      );
    }
    _notificationSubscription = measurement.lastValueStream.listen(
      (bytes) => _onNotification(deviceId, bytes),
      // 通知流自身的错误/关闭过去是静默的：不接住就完全看不到。
      onError: (Object error, StackTrace stack) {
        _log.error('hrs', 'notification stream failed', deviceId, error, stack);
        unawaited(_recoverNotify(deviceId, 'notify_error'));
      },
      onDone: () {
        _log.warn(
          'hrs',
          'notification stream closed',
          deviceId: deviceId,
          code: 'notify_closed',
        );
        unawaited(_recoverNotify(deviceId, 'notify_closed'));
      },
    );
  }

  /// 通知停了但链路可能还在：优先原地重订阅，超出重订阅预算才升级为整条重连。
  Future<void> _recoverNotify(String deviceId, String reason) async {
    if (_disposed || _resubscribing) {
      if (_resubscribing) {
        _log.debug(
          'ble',
          'resubscribe already in flight, ignoring reason=$reason',
          deviceId: deviceId,
          code: 'notify_resubscribe_busy',
        );
      }
      return;
    }
    final device = _connected;
    final now = DateTime.now();
    _resubscribeTimes.removeWhere(
      (at) => now.difference(at) > _notifyRecovery.window,
    );
    final action = _notifyRecovery.actionFor(
      deviceConnected: device?.isConnected ?? false,
      attemptsInWindow: _resubscribeTimes.length,
    );
    if (action == NotifyRecoveryAction.reconnect || device == null) {
      _log.warn(
        'ble',
        'notify recovery escalated to full reconnect reason=$reason '
            'attempts=${_resubscribeTimes.length}',
        deviceId: deviceId,
        code: 'notify_recovery_reconnect',
      );
      _onLinkDown(deviceId, reason);
      return;
    }
    _resubscribeTimes.add(now);
    _log.info(
      'ble',
      're-subscribing notifications reason=$reason '
          'attempt=${_resubscribeTimes.length}/${_notifyRecovery.maxAttempts}',
      deviceId: deviceId,
      code: 'notify_resubscribe',
    );
    _resubscribing = true;
    try {
      await _subscribeNotifications(device, deviceId);
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.subscribed));
      _log.info(
        'ble',
        'notifications re-subscribed reason=$reason',
        deviceId: deviceId,
        code: 'notify_resubscribed',
      );
    } catch (error, stack) {
      _log.error(
        'ble',
        'notify resubscribe failed reason=$reason',
        deviceId,
        error,
        stack,
      );
      _onLinkDown(deviceId, 'notify_resubscribe_failed');
    } finally {
      _resubscribing = false;
    }
  }

  void _watchConnectionState(BluetoothDevice device) {
    final deviceId = device.remoteId.str;
    unawaited(_connectionSubscription?.cancel());
    unawaited(_servicesResetSubscription?.cancel());
    _linkUp = false;
    _lastLinkState = null;
    _firstSampleLogged = false;
    // Services Changed（0x2A05）会让 CCCD 失效：通知从此静默，链路却还在。
    _servicesResetSubscription = device.onServicesReset.listen(
      (_) {
        _log.warn(
          'ble',
          'services reset (CCCD likely invalidated)',
          deviceId: deviceId,
          code: 'services_reset',
        );
        unawaited(_recoverNotify(deviceId, 'services_reset'));
      },
      onError: (Object error, StackTrace stack) {
        _log.error(
          'ble',
          'services reset stream failed',
          deviceId,
          error,
          stack,
        );
      },
    );
    _connectionSubscription = device.connectionState.listen(
      (state) {
        // 只记真实转变；订阅时吐出的初始值不算，否则每次连接开头都会多一行噪音。
        final previous = _lastLinkState;
        _lastLinkState = state;
        if (previous == state) return;
        switch (state) {
          case BluetoothConnectionState.connected:
            _linkUp = true;
            _log.info(
              'ble',
              'link state=connected',
              deviceId: deviceId,
              code: 'link_connected',
            );
          case BluetoothConnectionState.disconnected:
            final wasUp = _linkUp;
            _linkUp = false;
            // 初始值（订阅瞬间的当前状态）不是掉线事件。
            if (previous == null) return;
            _log.info(
              'ble',
              'link state=disconnected wasUp=$wasUp',
              deviceId: deviceId,
              code: 'link_disconnected',
            );
            if (!wasUp || _disposed) return;
            _onLinkDown(deviceId, 'gatt_disconnected');
        }
      },
      onError: (Object error, StackTrace stack) {
        _log.error(
          'ble',
          'connection state stream failed',
          deviceId,
          error,
          stack,
        );
      },
    );
  }

  /// 链路已断：清掉通知订阅、把 phase 退回 idle 并留下带错误码的日志。
  /// 自动重连由 HeartRateService 触发，这里不自己重试。
  void _onLinkDown(String deviceId, String code) {
    if (_disposed) return;
    _linkUp = false;
    unawaited(_notificationSubscription?.cancel());
    _notificationSubscription = null;
    unawaited(_servicesResetSubscription?.cancel());
    _servicesResetSubscription = null;
    _log.warn('ble', 'link lost, phase=idle', deviceId: deviceId, code: code);
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  void _onNotification(String deviceId, List<int> bytes) {
    // 使能 CCCD 时部分心率带会先发一条 0 长度通知。以前它会抛
    // HrsFormatException 记成 ERROR（现场日志里那条 "Empty measurement"），
    // 现在直接丢弃并留痕，不污染错误日志。
    if (bytes.isEmpty) {
      _log.debug(
        'hrs',
        'empty notification ignored',
        deviceId: deviceId,
        code: 'hrs_empty_notification',
      );
      return;
    }
    _emit(_snapshot.copyWith(lastRawBytes: bytes));
    _log.debug('hrs', 'raw=${_hex(bytes)}', deviceId: deviceId);
    HeartRateSample sample;
    try {
      sample = _decoder.decode(bytes);
    } on FormatException catch (error, stack) {
      _log.error('hrs', 'HRS parse failed: $error', deviceId, error, stack);
      return;
    }
    if (!_firstSampleLogged) {
      _firstSampleLogged = true;
      // 一行 info 就够证明数据流是活的，不用 debug 逐包刷。
      _log.info(
        'hrs',
        'first sample bpm=${sample.bpm} rr=${sample.rrIntervalsMs.length} '
            'contact=${sample.sensorContact}',
        deviceId: deviceId,
        code: 'hrs_first_sample',
      );
    }
    _samples.add(sample);
  }

  @override
  Future<void> forget(String deviceId) async {
    if (_connected?.remoteId.str == deviceId) {
      await disconnect();
    }
    _devices.remove(deviceId);
    _rssiById.remove(deviceId);
    _emit(
      _snapshot.copyWith(
        devices: _snapshot.devices
            .where((device) => device.id != deviceId)
            .toList(),
      ),
    );
    _log.info(
      'ble',
      'device removed from list',
      deviceId: deviceId,
      code: 'device_forgotten',
    );
  }

  @override
  Future<void> disconnect() async {
    // 让还在等 10 秒超时的扫描收尾失效，避免它稍后覆写 phase。
    _scanEpoch++;
    _resubscribeTimes.clear();
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _servicesResetSubscription?.cancel();
    _servicesResetSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _linkUp = false;
    final device = _connected;
    _connected = null;
    // 已经断开的设备不要再调 disconnect()：flutter_blue_plus 会为它等
    // androidDelay（默认 2 秒）来规避 Android 的 connect/disconnect 竞态，
    // 在重连路径上白等 2 秒会把空窗直接顶出 Relay 的 5 秒判定。
    if (device != null && device.isConnected) {
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.disconnecting));
      await device.disconnect();
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    _disposed = true;
    await _adapterSubscription?.cancel();
    await _nativeLogSubscription?.cancel();
    await FlutterBluePlus.stopScan();
    await _samples.close();
    await _snapshots.close();
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}
