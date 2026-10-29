import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/logging/app_logger.dart';
import 'ble_models.dart';
import 'heart_rate_sample.dart';
import 'heart_rate_source.dart';

/// Android reference transport. flutter_blue_plus is intentionally pinned in
/// pubspec.yaml. Background execution is owned by native code, not this plugin.
final class FlutterBluePlusSource implements HeartRateSource {
  FlutterBluePlusSource({AppLogger? logger}) : _log = logger ?? AppLogger.instance;

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
  BluetoothDevice? _connected;
  BleSnapshot _snapshot = const BleSnapshot();
  bool _disposed = false;

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
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
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
    _emit(_snapshot.copyWith(
      phase: BleConnectionPhase.scanning,
      devices: const [],
      clearError: true,
    ));
    late final StreamSubscription<List<ScanResult>> scanSubscription;
    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
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
      }).toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      _emit(_snapshot.copyWith(devices: infos));
    }, onError: (Object error, StackTrace stack) {
      _log.error('ble', 'Scan failed: $error', null, error, stack);
    });
    _subscriptions.add(scanSubscription);
    await FlutterBluePlus.startScan(withServices: [_hrsService], timeout: timeout);
    await Future<void>.delayed(timeout);
    await scanSubscription.cancel();
    _subscriptions.remove(scanSubscription);
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
  }

  @override
  Future<void> connect(String deviceId) async {
    final device = _devices[deviceId];
    if (device == null) throw ArgumentError.value(deviceId, 'deviceId', 'Scan first');
    await disconnect();
    _connected = device;
    _emit(_snapshot.copyWith(
      phase: BleConnectionPhase.connecting,
      connectedDeviceId: deviceId,
      clearError: true,
    ));
    await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _emit(_snapshot.copyWith(phase: BleConnectionPhase.idle));
      }
    });
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.discovering));
    final services = await device.discoverServices();
    BluetoothCharacteristic? measurement;
    for (final service in services) {
      if (service.uuid == _hrsService) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _hrsMeasurement) measurement = characteristic;
        }
      }
    }
    if (measurement == null) throw StateError('HRS 0x2A37 not found');
    await measurement.setNotifyValue(true);
    _notificationSubscription = measurement.lastValueStream.listen((bytes) {
      _emit(_snapshot.copyWith(lastRawBytes: bytes));
      _log.debug('hrs', 'raw=${_hex(bytes)}', deviceId);
      try {
        _samples.add(_decoder.decode(bytes));
      } on FormatException catch (error, stack) {
        _log.error('hrs', 'HRS parse failed: $error', deviceId, error, stack);
      }
    }));
    _emit(_snapshot.copyWith(phase: BleConnectionPhase.subscribed));
    _log.info('ble', 'HRS notifications subscribed', deviceId: deviceId);
  }

  @override
  Future<void> disconnect() async {
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    final device = _connected;
    if (device != null) {
      _emit(_snapshot.copyWith(phase: BleConnectionPhase.disconnecting));
      await device.disconnect();
      _connected = null;
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
    await FlutterBluePlus.stopScan();
    await _samples.close();
    await _snapshots.close();
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}
