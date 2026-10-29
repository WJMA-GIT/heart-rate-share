import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_models.dart';
import '../ble/heart_rate_sample.dart';
import '../ble/heart_rate_service.dart';
import '../core/l10n/strings_zh.dart';
import '../core/logging/app_logger.dart';
import '../core/profile/nickname.dart';
import '../core/profile/user_profile_store.dart';
import '../debug/debug_controller.dart';
import '../room/discovery.dart';
import '../room/protocol.dart';
import '../room/relay_server.dart';
import '../room/room_client.dart';

final class AppState extends ChangeNotifier {
  static String _initialNickname(String? candidate) {
    if (candidate == null || Nickname.validate(candidate) != null) {
      return Zh.guestUser;
    }
    return Nickname.normalize(candidate);
  }

  AppState({
    HeartRateService? heartRate,
    AppLogger? logger,
    String? nickname,
    UserProfileStore? profileStore,
  })  : logger = logger ?? AppLogger.instance,
        heartRate = heartRate ?? HeartRateService(logger: logger),
        _profileStore = profileStore ?? InMemoryUserProfileStore(),
        _nickname = _initialNickname(nickname) {
    debug = DebugController(this.logger);
    room = RoomClient(displayName: _nickname, logger: this.logger);
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
  final UserProfileStore _profileStore;
  String _nickname;
  String get nickname => _nickname;
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

  String? get currentRoomCode {
    if (room.state == RoomConnectionState.connected &&
        room.roomCode != null &&
        room.roomCode!.isNotEmpty) {
      return room.roomCode;
    }
    return _relay?.roomCode;
  }

  /// 校验通过并持久化成功后才更新显示名，避免 UI 与房间状态不一致。
  Future<NicknameValidationError?> updateNickname(String input) async {
    final value = Nickname.normalize(input);
    final validation = Nickname.validate(value);
    if (validation != null) return validation;
    await _profileStore.saveNickname(value);
    _nickname = value;
    room.updateDisplayName(value);
    notifyListeners();
    return null;
  }

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
