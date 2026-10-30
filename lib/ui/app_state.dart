import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ble/ble_models.dart';
import '../ble/heart_rate_sample.dart';
import '../ble/heart_rate_service.dart';
import '../core/l10n/strings_zh.dart';
import '../core/logging/app_logger.dart';
import '../core/profile/connection_profile.dart';
import '../core/profile/install_identity.dart';
import '../core/profile/nickname.dart';
import '../core/profile/user_profile_store.dart';
import '../debug/debug_controller.dart';
import '../room/discovery.dart';
import '../room/protocol.dart';
import '../room/relay_server.dart';
import '../room/room_client.dart';
import '../room/room_transport.dart';
import '../room/sequence_counter.dart';

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
    String? memberId,
    SequenceCounter? sequence,
    IdentityStore? identityStore,
    List<ConnectionProfile> recentProfiles = const [],
    RoomTls? tls,
  }) : logger = logger ?? AppLogger.instance,
       heartRate = heartRate ?? HeartRateService(logger: logger),
       _profileStore = profileStore ?? InMemoryUserProfileStore(),
       _identity = identityStore ?? InMemoryIdentityStore(),
       _nickname = _initialNickname(nickname) {
    _recentProfiles = recentProfiles;
    debug = DebugController(this.logger);
    room = RoomClient(
      displayName: _nickname,
      memberId: memberId,
      sequence: sequence,
      tls: tls ?? RoomTls.fromEnvironment(),
      logger: this.logger,
    );
    discovery = UnimplementedRoomDiscovery(logger: this.logger);
    _subscriptions = [
      this.heartRate.samples.listen(_onSample),
      this.heartRate.snapshots.listen((_) => notifyListeners()),
      room.members.listen((members) {
        _members = members;
        _notify();
      }),
      room.states.listen((_) => notifyListeners()),
    ];
  }

  final AppLogger logger;
  final HeartRateService heartRate;
  final UserProfileStore _profileStore;
  final IdentityStore _identity;
  List<ConnectionProfile> _recentProfiles = const [];
  ConnectionMode? _mode;
  String _nickname;

  /// 最近连接配置（最新的在前）。与安装标识共用同一套本地存储。
  List<ConnectionProfile> get recentProfiles =>
      List.unmodifiable(_recentProfiles);

  /// 当前房间模式。null = 还没做选择（**不默认进本机房间**）。
  ConnectionMode? get roomMode => _mode;

  /// 是否钉住了服务端证书指纹（自签场景）。设置页用它显示当前校验方式。
  bool get pinnedCertificate => room.tlsPinned;

  String get nickname => _nickname;
  late final DebugController debug;
  late final RoomClient room;
  late final UnimplementedRoomDiscovery discovery;
  late final List<StreamSubscription<Object?>> _subscriptions;

  /// dispose 之后异步收尾（停 relay / 关连接）还会走到 notifyListeners，
  /// 直接调会命中 ChangeNotifier 的 use-after-dispose 断言。
  bool _disposed = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

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
    _notify();
    return null;
  }

  void _onSample(HeartRateSample value) {
    room.report(
      bpm: value.bpm,
      rrIntervalsMs: value.rrIntervalsMs,
      sensorContact: value.sensorContact,
      measuredAt: value.receivedAt,
    );
    _notify();
  }

  /// 远端/官方：先停掉本机 relay（两者互斥），再连上去并记住这次配置。
  Future<void> connectProfile(
    ConnectionProfile profile, {
    String? roomCode,
  }) async {
    if (profile.mode == ConnectionMode.local) {
      await createLocalRoom();
      return;
    }
    await stopRelay();
    final effectiveRoom = (roomCode ?? profile.roomCode)?.trim();
    _mode = profile.mode;
    _notify();
    await room.connect(profile.toUri(roomCode: effectiveRoom));
    await _rememberProfile(profile.copyWith(roomCode: effectiveRoom));
  }

  /// 本机房间：起 Relay 再自己连进去（原来需要用户手填 127.0.0.1，现在是显式一键）。
  Future<void> createLocalRoom() async {
    await room.disconnect();
    await startRelay();
    final relay = _relay;
    if (relay == null) throw StateError('Relay did not start');
    _mode = ConnectionMode.local;
    _notify();
    await room.connect(
      ConnectionProfile.local().toUri(
        portOverride: relay.port,
        roomCode: relay.roomCode,
      ),
    );
    await _rememberProfile(ConnectionProfile.local());
  }

  Future<void> disconnectRoom() async {
    await room.disconnect();
    await stopRelay();
    _mode = null;
    _notify();
  }

  /// 从最近列表里删掉一条（只删本地记录，不影响正在跑的房间）。
  Future<void> forgetProfile(ConnectionProfile profile) async {
    _recentProfiles = _recentProfiles
        .where((item) => item.id != profile.id)
        .toList();
    _notify();
    await _persistProfiles();
  }

  Future<void> _rememberProfile(ConnectionProfile used) async {
    _recentProfiles = RecentProfiles.touch(_recentProfiles, used);
    _notify();
    await _persistProfiles();
  }

  Future<void> _persistProfiles() async {
    try {
      await _identity.saveConnectionProfiles(
        RecentProfiles.encode(_recentProfiles),
      );
    } catch (error, stack) {
      // 存不下也不能挡住连接：下一次仍可用内存里的列表。
      logger.error('room', 'Save recent profiles failed', null, error, stack);
    }
  }

  /// 前台/后台切换：切回前台时检查房间 socket 是否还活着（后台冻结期间
  /// 可能已经死掉且没有任何回调），必要时立刻重连。
  void onAppLifecycle(AppLifecycleState state) {
    logger.info('app', 'lifecycle=${state.name}', code: 'app_lifecycle');
    if (state == AppLifecycleState.resumed) {
      unawaited(room.onAppResumed());
    }
  }

  Future<void> startRelay() async {
    await _relay?.stop();
    _relay = RelayServer(logger: logger);
    await _relay!.start();
    _notify();
  }

  Future<void> stopRelay() async {
    await _relay?.stop();
    _relay = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
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
