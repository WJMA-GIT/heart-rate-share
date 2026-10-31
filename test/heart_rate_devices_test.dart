import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/ble_models.dart';
import 'package:heartrate/ble/heart_rate_sample.dart';
import 'package:heartrate/ble/heart_rate_service.dart';
import 'package:heartrate/ble/heart_rate_source.dart';
import 'package:heartrate/core/config/app_config.dart';

/// 只关心"设备列表"这一层的假传输层。
final class FakeDeviceSource implements HeartRateSource {
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();
  final forgotten = <String>[];
  final connectCalls = <String>[];
  int disconnectCalls = 0;

  var devices = <BleDeviceInfo>[
    const BleDeviceInfo(id: 'AA:BB:CC:01', name: 'Polar H10', rssi: -52),
    const BleDeviceInfo(id: 'AA:BB:CC:02', name: 'Garmin HRM', rssi: -67),
  ];
  BleSnapshot _snapshot = const BleSnapshot();

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<BleSnapshot> get snapshots => _snapshots.stream;

  void emit(BleSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  void emitDevices() => emit(
    _snapshot.copyWith(phase: BleConnectionPhase.scanning, devices: devices),
  );

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    bool onlyHrs = true,
  }) async => emitDevices();

  @override
  Future<void> connect(
    String deviceId, {
    Duration timeout = AppConfig.connectTimeout,
  }) async {
    connectCalls.add(deviceId);
    emit(
      _snapshot.copyWith(
        phase: BleConnectionPhase.subscribed,
        connectedDeviceId: deviceId,
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  @override
  Future<void> forget(String deviceId) async {
    forgotten.add(deviceId);
    devices = devices.where((device) => device.id != deviceId).toList();
    emitDevices();
  }

  @override
  Future<void> dispose() async {
    await _samples.close();
    await _snapshots.close();
  }
}

Future<void> waitFor(
  bool Function() predicate, {
  String reason = 'condition',
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeDeviceSource source;
  late HeartRateService service;

  setUp(() {
    source = FakeDeviceSource();
    service = HeartRateService(source: source);
  });

  tearDown(() => service.dispose());

  test('扫描结果按列表形式暴露（名称 / RSSI / 标识）', () async {
    await service.scan();
    await waitFor(
      () => service.snapshot.devices.length == 2,
      reason: '两台设备应出现在列表里',
    );
    final first = service.snapshot.devices.firstWhere(
      (device) => device.id == 'AA:BB:CC:01',
    );
    expect(first.name, 'Polar H10');
    expect(first.rssi, -52);
  });

  test('点击某一行连接，再断开', () async {
    await service.scan();
    await service.connect('AA:BB:CC:02');
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '应进入 subscribed',
    );
    expect(source.connectCalls, ['AA:BB:CC:02']);
    expect(service.snapshot.connectedDeviceId, 'AA:BB:CC:02');

    await service.disconnect();
    expect(source.disconnectCalls, 1);
    expect(service.snapshot.phase, BleConnectionPhase.idle);
  });

  test('从列表移除设备：先断开（若是当前连接）再从列表消失', () async {
    await service.scan();
    await service.connect('AA:BB:CC:01');
    await waitFor(
      () => service.snapshot.phase == BleConnectionPhase.subscribed,
      reason: '应进入 subscribed',
    );

    await service.forget('AA:BB:CC:01');
    expect(source.forgotten, contains('AA:BB:CC:01'));
    expect(source.disconnectCalls, 1, reason: '移除当前连接前必须先断开');
    await waitFor(
      () => !service.snapshot.devices.any((d) => d.id == 'AA:BB:CC:01'),
      reason: '该设备应从列表里移除',
    );
  });

  test('移除一台没连着的设备不会触发断开', () async {
    await service.scan();
    await service.forget('AA:BB:CC:02');
    expect(source.forgotten, ['AA:BB:CC:02']);
    expect(source.disconnectCalls, 0);
    await waitFor(() => service.snapshot.devices.length == 1, reason: '只剩一台');
  });
}
