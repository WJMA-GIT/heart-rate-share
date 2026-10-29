import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/ble_models.dart';
import 'package:heartrate/ble/heart_rate_sample.dart';
import 'package:heartrate/ble/heart_rate_service.dart';
import 'package:heartrate/ble/heart_rate_source.dart';
import 'package:heartrate/ble/reconnect_policy.dart';
import 'package:heartrate/core/config/app_config.dart';
import 'package:heartrate/core/logging/app_logger.dart';

/// 可以被测试任意摆布的传输层：记录每次 connect、模拟掉线与连接失败。
final class FakeHeartRateSource implements HeartRateSource {
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();
  final connectCalls = <String>[];
  final timeouts = <Duration>[];

  /// 剩余多少次 connect 直接失败（模拟 GATT 133 / 超时）。
  int failuresRemaining = 0;

  /// 真实传输层在 connect 开头会先 disconnect，于是先吐一个 idle。
  bool emitIdleOnConnect = true;

  /// 扫描收尾时吐一个 idle（0.3.2 的行为，正是现场日志里那条假掉线）。
  bool scanEndsWithIdle = false;

  BleSnapshot _snapshot = const BleSnapshot();

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<BleSnapshot> get snapshots => _snapshots.stream;

  void emit(BleSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  /// 模拟系统侧掉线：传输层把 phase 退回 idle。
  void dropLink() {
    emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    emit(_snapshot.copyWith(phase: BleConnectionPhase.scanning));
    if (scanEndsWithIdle) {
      emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
    }
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration timeout = AppConfig.connectTimeout,
  }) async {
    connectCalls.add(deviceId);
    timeouts.add(timeout);
    if (emitIdleOnConnect) {
      emit(
        _snapshot.copyWith(
          phase: BleConnectionPhase.idle,
          connectedDeviceId: deviceId,
        ),
      );
    }
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('gatt 133');
    }
    emit(
      _snapshot.copyWith(
        phase: BleConnectionPhase.connecting,
        connectedDeviceId: deviceId,
      ),
    );
    emit(_snapshot.copyWith(phase: BleConnectionPhase.subscribed));
  }

  @override
  Future<void> disconnect() async {
    emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  @override
  Future<void> dispose() async {
    await _samples.close();
    await _snapshots.close();
  }
}

const _fastPolicy = ReconnectPolicy(
  maxAttempts: 3,
  baseDelay: Duration(milliseconds: 5),
  maxDelay: Duration(milliseconds: 10),
);

/// 轮询等待条件成立，避免依赖固定 sleep 造成抖动。
Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：$reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeHeartRateSource source;
  late HeartRateService service;

  setUp(() {
    source = FakeHeartRateSource();
    service = HeartRateService(source: source, reconnectPolicy: _fastPolicy);
  });

  tearDown(() => service.dispose());

  test('系统侧掉线后自动重连，并回到 subscribed', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    expect(source.connectCalls, hasLength(1));
    // 快照是异步投递的，等一拍再断言（这本身也是重连监督器要面对的时序）。
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '首次连接应进入 subscribed',
    );

    source.dropLink();
    await waitFor(
      () =>
          source.connectCalls.length == 2 &&
          service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '掉线后应自动重连',
    );

    expect(source.connectCalls.last, 'AA:BB:CC:DD:EE:FF');
    // 重连用更短的连接超时，才可能留在 Relay 的 5 秒离线窗口内。
    expect(source.timeouts.last, AppConfig.reconnectConnectTimeout);
  });

  test('用户主动断开后不再自动重连', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    await service.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(source.connectCalls, hasLength(1));
    expect(service.snapshot.phase, BleConnectionPhase.idle);
  });

  test('连接流程内部的 idle 快照不会被误判成掉线', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(source.connectCalls, hasLength(1), reason: '不应触发重连风暴');
    expect(service.snapshot.phase, BleConnectionPhase.subscribed);
  });

  test('重连失败会按退避重试，配额用尽后停在 reconnectFailed', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    source.failuresRemaining = 100;
    source.dropLink();

    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.reconnectFailed,
      reason: '重连配额应被用尽',
    );
    // 首次连接 1 次 + 策略允许的 3 次重试。
    expect(source.connectCalls, hasLength(1 + _fastPolicy.maxAttempts));

    // 放弃后不应再继续打设备。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(source.connectCalls, hasLength(1 + _fastPolicy.maxAttempts));
  });

  test('重连成功后退避计数复位，下一次掉线仍能快速接回', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    source.failuresRemaining = 1;
    source.dropLink();
    await waitFor(
      () =>
          source.connectCalls.length == 3 &&
          service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '一次失败后应重试成功',
    );

    source.dropLink();
    await waitFor(
      () =>
          source.connectCalls.length == 4 &&
          service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '第二次掉线应重新从第一次退避开始',
    );
    expect(service.snapshot.phase, BleConnectionPhase.subscribed);
  });

  test('扫描收尾吐出的 idle 不会被当成掉线（现场日志里的假断连）', () async {
    await service.connect('AA:BB:CC:DD:EE:FF');
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '首次连接应进入 subscribed',
    );

    // 0.3.2 里 startScan 超时后无条件写 idle，把已建立的连接打成"空闲"。
    source.scanEndsWithIdle = true;
    await service.scan();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(source.connectCalls, hasLength(1), reason: '不该因为扫描收尾而重连');
  });

  test('phase 没变化时不重复写 info 日志（现场日志 98% 是重复 idle）', () async {
    final before = AppLogger.instance.entries.length;
    await service.connect('AA:BB:CC:DD:EE:FF');
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '首次连接应进入 subscribed',
    );
    // 模拟每秒一条通知：phase 不变，只有 lastRawBytes 在变。
    for (var i = 0; i < 20; i++) {
      source.emit(
        const BleSnapshot(phase: BleConnectionPhase.subscribed)
            .copyWith(lastRawBytes: [0x16, 60 + i]),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final phaseLines = AppLogger.instance.entries
        .skip(before)
        .where((entry) => entry.message.startsWith('connection phase='))
        .length;
    // 1 次 connecting/discovering 由假源省略，实际只会记 subscribed 这一条。
    expect(phaseLines, lessThanOrEqualTo(2), reason: '重复 phase 不该逐条刷日志');
  });

  test('失败与重连都会留下带模块/设备/错误码的日志', () async {
    final before = AppLogger.instance.entries.length;
    await service.connect('AA:BB:CC:DD:EE:FF');
    source.failuresRemaining = 100;
    source.dropLink();
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.reconnectFailed,
      reason: '重连配额应被用尽',
    );

    final entries = AppLogger.instance.entries.skip(before).toList();
    final ble = entries.where((entry) => entry.module == 'ble').toList();
    expect(
      ble.any((entry) => entry.errorCode == 'reconnect_scheduled'),
      isTrue,
      reason: '掉线要有一条 reconnect_scheduled 日志',
    );
    expect(
      ble.any(
        (entry) =>
            entry.errorCode == 'reconnect_exhausted' &&
            entry.deviceId == 'AA:BB:CC:DD:EE:FF',
      ),
      isTrue,
      reason: '放弃重连要带设备标识与错误码',
    );
    expect(
      ble.any((entry) => entry.level == LogLevel.error),
      isTrue,
      reason: '每次重连失败都要记 error',
    );
  });
}
