import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'ble_models.dart';
import 'flutter_blue_plus_source.dart';
import 'heart_rate_sample.dart';
import 'heart_rate_source.dart';
import '../core/platform/foreground_lease.dart';
import 'reconnect_policy.dart';

/// 采集层门面：负责平台选择、流编排，以及**断连后的自动重连监督**。
///
/// 监督器为什么放在这里而不是传输层：传输层只知道「这条链路断了」，
/// 而「该不该重连」是应用策略（用户有没有主动断开、退避到第几次、
/// 是否已经放弃），放在服务层才能用假数据源做单元测试。
final class HeartRateService {
  HeartRateService({
    HeartRateSource? source,
    AppLogger? logger,
    ReconnectPolicy? reconnectPolicy,
    ForegroundLease? foreground,
  }) : _source = source ?? _defaultSource(),
       _foreground = foreground ?? ForegroundLease.instance,
       _log = logger ?? AppLogger.instance,
       _policy = reconnectPolicy ?? const ReconnectPolicy() {
    _sampleSubscription = _source.samples.listen(_onSample);
    _snapshotSubscription = _source.snapshots.listen(_onSnapshot);
  }

  final HeartRateSource _source;
  final AppLogger _log;
  final ReconnectPolicy _policy;
  final ForegroundLease _foreground;
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();
  late final StreamSubscription<HeartRateSample> _sampleSubscription;
  late final StreamSubscription<BleSnapshot> _snapshotSubscription;
  BleSnapshot _snapshot = const BleSnapshot();
  HeartRateSample? _latest;

  /// 当前盯着的设备。为 null 表示没有连接意图，不该自动重连。
  String? _target;

  /// 用户主动断开后就不要再自动重连，直到他再次点连接。
  bool _userDisconnect = true;

  /// 一次连接流程正在进行（传输层内部会先 disconnect 再 connect，
  /// 期间产生的 idle 快照不能当成掉线，否则会重连风暴）。
  bool _attemptInProgress = false;

  /// 是否真的建立过可用链路（观察到 subscribed）。
  ///
  /// 快照流是异步投递的，用「当时是否在连接中」判断掉线会踩时序；改成用这个
  /// 同步复位的标志：任何一次连接尝试开始前就置 false，只有真正看到
  /// subscribed 才置 true。这样 idle 快照无论何时送达都不会误判。
  bool _linkEstablished = false;

  Timer? _retryTimer;
  int _failures = 0;

  bool _disposed = false;

  /// 一次扫描正在进行。扫描收尾写的 `idle` 不是掉线。
  bool _scanning = false;

  Stream<HeartRateSample> get samples => _samples.stream;
  Stream<BleSnapshot> get snapshots => _snapshots.stream;
  BleSnapshot get snapshot => _snapshot;
  HeartRateSample? get latest => _latest;

  static HeartRateSource _defaultSource() {
    if (kIsWeb) {
      return UnsupportedHeartRateSource('web', 'Not a target platform.');
    }
    if (Platform.isAndroid) return FlutterBluePlusSource();
    // TODO(iOS): Swift CoreBluetooth HRS central is a stub because native
    // background/restoration behavior must be designed and tested on hardware.
    // TODO(Windows): C++/WinRT HRS central is a stub because adapter capability
    // and the Store-packaged plugin boundary require real-device validation.
    return UnsupportedHeartRateSource(
      Platform.operatingSystem,
      'See native/${Platform.isIOS ? 'ios' : 'windows'} TODO stubs.',
    );
  }

  void _onSnapshot(BleSnapshot next) {
    final previous = _snapshot.phase;
    _snapshot = next;
    _snapshots.add(next);
    // 只在 phase 变化时记一行：现场日志里 863/879 行都是重复的 phase=idle，
    // 把真正的证据全淹了。每条通知都会带一个 snapshot，不能逐条写 info。
    if (previous != next.phase) {
      _log.info(
        'ble',
        'connection phase=${next.phase.name}',
        deviceId: next.connectedDeviceId,
      );
    }
    switch (next.phase) {
      case BleConnectionPhase.subscribed:
        // 链路真正可用（notify 已订阅）才复位退避计数。
        _linkEstablished = true;
        _failures = 0;
        _cancelRetry();
        unawaited(_startForeground());
      case BleConnectionPhase.idle:
        // 只有「本来连着」的 idle 才是掉线；连接流程内部的 idle 一律忽略。
        if (!_linkEstablished) break;
        // 扫描期间传输层可能还在写扫描相关快照，别把它当成掉线。
        if (_scanning) break;
        _linkEstablished = false;
        _scheduleRetry('phase=idle');
      case BleConnectionPhase.error:
        _linkEstablished = false;
        _scheduleRetry('phase=error');
      case _:
        break;
    }
  }

  void _onSample(HeartRateSample sample) {
    _latest = sample;
    _samples.add(sample);
    _log.debug(
      'hrs',
      'BPM=${sample.bpm} RR=${sample.rrIntervalsMs} contact=${sample.sensorContact}',
      deviceId: _snapshot.connectedDeviceId,
    );
  }

  Future<void> scan() async {
    _scanning = true;
    try {
      await _guard(() => _source.startScan());
    } finally {
      // 快照是异步投递的：先让扫描期间产生的快照被消费掉，再解除标志，
      // 否则收尾那条 idle 会落在标志复位之后，防御就失效了。
      await Future<void>.delayed(Duration.zero);
      _scanning = false;
    }
  }

  Future<void> connect(String id) async {
    _userDisconnect = false;
    _target = id;
    _failures = 0;
    _cancelRetry();
    await _guard(() => _connect(id, AppConfig.connectTimeout));
  }

  Future<void> disconnect() async {
    _userDisconnect = true;
    _target = null;
    _failures = 0;
    _linkEstablished = false;
    _cancelRetry();
    await _guard(_source.disconnect);
    await _stopForeground();
  }

  /// 忽略/删除一台设备：正连着就先按用户意图断开（不自动重连）。
  Future<void> forget(String deviceId) async {
    if (_target == deviceId) await disconnect();
    await _guard(() => _source.forget(deviceId));
  }

  Future<void> _connect(String id, Duration timeout) async {
    _attemptInProgress = true;
    _linkEstablished = false;
    try {
      await _source.connect(id, timeout: timeout);
    } finally {
      _attemptInProgress = false;
    }
  }

  /// 掉线后按 [ReconnectPolicy] 排一次重连；次数用尽则停在
  /// [BleConnectionPhase.reconnectFailed]，等用户手动重连。
  void _scheduleRetry(String reason) {
    if (_disposed || _userDisconnect || _target == null) return;
    if (_attemptInProgress || _retryTimer != null) return;
    final delay = _policy.delayFor(_failures);
    if (delay == null) {
      _log.warn(
        'ble',
        'reconnect exhausted attempts=$_failures',
        deviceId: _target,
        code: 'reconnect_exhausted',
      );
      _emitPhase(BleConnectionPhase.reconnectFailed);
      unawaited(_stopForeground());
      return;
    }
    _log.warn(
      'ble',
      'reconnect scheduled in ${delay.inMilliseconds}ms '
          'attempt=${_failures + 1}/${_policy.maxAttempts} reason=$reason',
      deviceId: _target,
      code: 'reconnect_scheduled',
    );
    _emitPhase(BleConnectionPhase.reconnecting);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_runRetry());
    });
  }

  Future<void> _runRetry() async {
    final id = _target;
    if (_disposed || _userDisconnect || id == null) return;
    _log.info(
      'ble',
      'reconnect attempt=${_failures + 1}',
      deviceId: id,
      code: 'reconnect_attempt',
    );
    var connected = false;
    _attemptInProgress = true;
    _linkEstablished = false;
    try {
      await _source.connect(id, timeout: AppConfig.reconnectConnectTimeout);
      connected = true;
      _log.info(
        'ble',
        'reconnect succeeded after $_failures failed attempt(s)',
        deviceId: id,
        code: 'reconnect_ok',
      );
      _failures = 0;
    } catch (error, stack) {
      _failures++;
      _log.error(
        'ble',
        'reconnect failed attempt=$_failures',
        id,
        error,
        stack,
      );
    } finally {
      _attemptInProgress = false;
    }
    if (!connected) _scheduleRetry('retry_failed');
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _emitPhase(BleConnectionPhase phase) {
    if (_disposed || _snapshot.phase == phase) return;
    _snapshot = _snapshot.copyWith(phase: phase);
    _snapshots.add(_snapshot);
    _log.info(
      'ble',
      'phase=${phase.name}',
      deviceId: _snapshot.connectedDeviceId,
    );
  }

  /// Android 前台服务：只在链路可用期间开着，避免息屏/后台被系统回收。
  /// BLE 只是前台服务的持有者之一（另一个是房间连接），见 ForegroundLease。
  Future<void> _startForeground() => _foreground.acquire('ble');

  Future<void> _stopForeground() => _foreground.release('ble');

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      _snapshot = _snapshot.copyWith(
        phase: BleConnectionPhase.error,
        lastError: '$error',
      );
      _snapshots.add(_snapshot);
      _log.error(
        'ble',
        'BLE operation failed: $error',
        _snapshot.connectedDeviceId,
        error,
        stack,
      );
      rethrow;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelRetry();
    await _stopForeground();
    await _sampleSubscription.cancel();
    await _snapshotSubscription.cancel();
    await _source.dispose();
    await _samples.close();
    await _snapshots.close();
  }
}
