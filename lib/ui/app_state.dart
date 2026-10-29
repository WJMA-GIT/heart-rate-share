import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_models.dart';
import '../ble/heart_rate_sample.dart';
import '../ble/heart_rate_service.dart';
import '../core/logging/app_logger.dart';
import '../debug/debug_controller.dart';
import '../room/discovery.dart';
import '../room/protocol.dart';
import '../room/relay_server.dart';
import '../room/room_client.dart';

final class AppState extends ChangeNotifier {
  AppState({HeartRateService? heartRate, AppLogger? logger})
      : logger = logger ?? AppLogger.instance,
        heartRate = heartRate ?? HeartRateService(logger: logger) {
    debug = DebugController(this.logger);
    room = RoomClient(displayName: 'Guest', logger: this.logger);
    discovery = UnimplementedRoomDiscovery(logger: this.logger);
    _subscriptions = [
      this.heartRate.samples.listen(_onSample),
      this.heartRate.snapshots.listen((_) => notifyListeners()),
      room.members.listen((members) {
        _members = members;
        notifyListeners();
      }),
      room.states.listen((_) => notifyListeners()),
    ];
  }

  final AppLogger logger;
  final HeartRateService heartRate;
  late final DebugController debug;
  late final RoomClient room;
  late final UnimplementedRoomDiscovery discovery;
  late final List<StreamSubscription<Object?>> _subscriptions;
  RelayServer? _relay;
  List<MemberState> _members = const [];
  List<MemberState> get members => _members;
  BleSnapshot get ble => heartRate.snapshot;
  HeartRateSample? get sample => heartRate.latest;
  RelayServer? get relay => _relay;

  void _onSample(HeartRateSample value) {
    room.report(
      bpm: value.bpm,
      rrIntervalsMs: value.rrIntervalsMs,
      sensorContact: value.sensorContact,
      measuredAt: value.receivedAt,
    );
    notifyListeners();
  }

  Future<void> startRelay() async {
    await _relay?.stop();
    _relay = RelayServer(logger: logger);
    await _relay!.start();
    notifyListeners();
  }

  Future<void> stopRelay() async {
    await _relay?.stop();
    _relay = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(stopRelay());
    unawaited(room.dispose());
    unawaited(heartRate.dispose());
    unawaited(discovery.dispose());
    debug.dispose();
    super.dispose();
  }
}
