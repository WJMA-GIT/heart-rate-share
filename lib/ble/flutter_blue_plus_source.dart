import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'ble_models.dart';
import 'heart_rate_sample.dart';
import 'heart_rate_source.dart';

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
    // 扫描结束时如果链路仍然活着，不要把 phase 退回 idle：
    // 服务层把「已连状态下出现 idle」当作掉线，会误触发一次重连。
    if (!(_connected?.isConnected ?? false)) {
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
    } else {
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.subscribed));
    }
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
    await disconnect();
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
      stage = 'discover';
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
      stage = 'subscribe';
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
          _log.error(
            'hrs',
            'notification stream failed',
            deviceId,
            error,
            stack,
          );
          _onLinkDown(deviceId, 'notify_error');
        },
        onDone: () {
          _log.warn(
            'hrs',
            'notification stream closed',
            deviceId: deviceId,
            code: 'notify_closed',
          );
          _onLinkDown(deviceId, 'notify_closed');
        },
      );
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

  void _watchConnectionState(BluetoothDevice device) {
    final deviceId = device.remoteId.str;
    unawaited(_connectionSubscription?.cancel());
    _linkUp = false;
    _connectionSubscription = device.connectionState.listen(
      (state) {
        switch (state) {
          case BluetoothConnectionState.connected:
            _linkUp = true;
          case BluetoothConnectionState.disconnected:
            final wasUp = _linkUp;
            _linkUp = false;
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
    _log.warn('ble', 'link lost, phase=idle', deviceId: deviceId, code: code);
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  void _onNotification(String deviceId, List<int> bytes) {
    _emit(_snapshot.copyWith(lastRawBytes: bytes));
    _log.debug('hrs', 'raw=${_hex(bytes)}', deviceId: deviceId);
    try {
      _samples.add(_decoder.decode(bytes));
    } on FormatException catch (error, stack) {
      _log.error('hrs', 'HRS parse failed: $error', deviceId, error, stack);
    }
  }

  @override
  Future<void> disconnect() async {
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
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
