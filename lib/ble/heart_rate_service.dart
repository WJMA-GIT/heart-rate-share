import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../core/logging/app_logger.dart';
import 'ble_models.dart';
import 'flutter_blue_plus_source.dart';
import 'heart_rate_sample.dart';
import 'heart_rate_source.dart';

final class HeartRateService {
  HeartRateService({HeartRateSource? source, AppLogger? logger})
      : _source = source ?? _defaultSource(),
        _log = logger ?? AppLogger.instance {
    _sampleSubscription = _source.samples.listen(_onSample);
    _snapshotSubscription = _source.snapshots.listen(_onSnapshot);
  }

  final HeartRateSource _source;
  final AppLogger _log;
  final _decoder = const HrsDecoder();
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _snapshots = StreamController<BleSnapshot>.broadcast();
  late final StreamSubscription<HeartRateSample> _sampleSubscription;
  late final StreamSubscription<BleSnapshot> _snapshotSubscription;
  BleSnapshot _snapshot = const BleSnapshot();
  HeartRateSample? _latest;

  Stream<HeartRateSample> get samples => _samples.stream;
  Stream<BleSnapshot> get snapshots => _snapshots.stream;
  BleSnapshot get snapshot => _snapshot;
  HeartRateSample? get latest => _latest;

  static HeartRateSource _defaultSource() {
    if (kIsWeb) return UnsupportedHeartRateSource('web', 'Not a target platform.');
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
    _snapshot = next;
    _snapshots.add(next);
    _log.info('ble', 'connection phase=${next.phase.name}', deviceId: next.connectedDeviceId);
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

  Future<void> scan() => _guard(() => _source.startScan());
  Future<void> connect(String id) => _guard(() => _source.connect(id));
  Future<void> disconnect() => _guard(_source.disconnect);

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      _snapshot = _snapshot.copyWith(
        phase: BleConnectionPhase.error,
        lastError: '$error',
      );
      _snapshots.add(_snapshot);
      _log.error('ble', 'BLE operation failed: $error', _snapshot.connectedDeviceId, error, stack);
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _sampleSubscription.cancel();
    await _snapshotSubscription.cancel();
    await _source.dispose();
    await _samples.close();
    await _snapshots.close();
  }
}
