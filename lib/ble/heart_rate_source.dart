import 'dart:async';

import 'ble_models.dart';
import 'heart_rate_sample.dart';

abstract interface class HeartRateSource {
  Stream<HeartRateSample> get samples;
  Stream<BleSnapshot> get snapshots;
  Future<void> startScan({Duration timeout});
  Future<void> connect(String deviceId);
  Future<void> disconnect();
  Future<void> dispose();
}

final class UnsupportedHeartRateSource implements HeartRateSource {
  UnsupportedHeartRateSource(this.platform, this.reason);
  final String platform;
  final String reason;
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<BleSnapshot> get snapshots => _snapshots.stream;

  Never _unsupported() => throw UnsupportedError(
        '$platform native HRS transport is not implemented: $reason',
      );

  @override
  Future<void> startScan(
          {Duration timeout = const Duration(seconds: 10)}) async =>
      _unsupported();
  @override
  Future<void> connect(String deviceId) async => _unsupported();
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await _samples.close();
    await _snapshots.close();
  }
}
