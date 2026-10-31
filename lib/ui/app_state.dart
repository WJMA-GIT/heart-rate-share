import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ble/ble_models.dart';
import '../ble/heart_rate_sample.dart';
import '../ble/heart_rate_service.dart';
import '../core/l10n/strings_zh.dart';
import '../core/logging/app_logger.dart';
import '../core/platform/room_overlay.dart';
import '../core/profile/connection_profile.dart';
import '../core/profile/install_identity.dart';
import '../core/profile/nickname.dart';
import '../core/profile/user_profile_store.dart';
import '../debug/debug_controller.dart';
import '../room/discovery.dart';
import '../room/protocol.dart';
import '../room/room_client.dart';
import '../room/room_transport.dart';
import '../room/sequence_counter.dart';
import 'widgets/heart_rate_chart.dart';

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
    HeartRateSeries? series,
    RoomOverlayBackend? overlayBackend,
    bool initialOverlayEnabled = false,
    double initialOverlayAlpha = OverlayDefaults.defaultAlpha,
    bool initialOverlayChart = OverlayDefaults.defaultShowChart,
    DateTime Function()? clock,
  }) : logger = logger ?? AppLogger.instance,
       heartRate = heartRate ?? HeartRateService(logger: logger),
       _profileStore = profileStore ?? InMemoryUserProfileStore(),
       _identity = identityStore ?? InMemoryIdentityStore(),
       _overlayBackend = overlayBackend ?? const PlatformRoomOverlay(),
       series = series ?? HeartRateSeries(),
       _overlayEnabled = initialOverlayEnabled,
       _overlayAlpha = initialOverlayAlpha
           .clamp(OverlayDefaults.minAlpha, 1.0)
           .toDouble(),
       _overlayChart = initialOverlayChart,
       _clock = clock ?? DateTime.now,
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
        _trackMemberSamples();
        _notify();
        unawaited(_syncOverlay());
      }),
      room.states.listen((_) {
        _notify();
        unawaited(_syncOverlay());
      }),
    ];
  }

  final AppLogger logger;
  final HeartRateService heartRate;
  final UserProfileStore _profileStore;
  final IdentityStore _identity;
  final RoomOverlayBackend _overlayBackend;
  final DateTime Function() _clock;

  /// 首页折线的数据源：只装真实采样，超窗/超量即丢弃。
  final HeartRateSeries series;
  List<ConnectionProfile> _recentProfiles = const [];
  ConnectionMode? _mode;
  String _nickname;
  bool _overlayEnabled;
  double _overlayAlpha;
  bool _overlayChart;

  /// 悬浮窗当前状态（只用于"变了才写日志"，不参与任何逻辑判断）。
  String _overlayState = 'idle';

  /// 悬浮窗小折线的数据源：每个成员一条，1 Hz 上报的接收时刻，有界（60 秒）。
  final Map<String, HeartRateSeries> _memberSeries = {};
  bool _overlayVisible = false;
  Future<void> _overlayQueue = Future<void>.value();

  /// 最近连接配置（最新的在前）。与安装标识共用同一套本地存储。
  List<ConnectionProfile> get recentProfiles =>
      List.unmodifiable(_recentProfiles);

  /// 当前房间模式。null = 还没做选择（**不默认进任何房间**）。
  ConnectionMode? get roomMode => _mode;

  /// 是否钉住了服务端证书指纹（自签场景）。设置页用它显示当前校验方式。
  bool get pinnedCertificate => room.tlsPinned;

  String get nickname => _nickname;
  late final DebugController debug;
  late final RoomClient room;
  late final UnimplementedRoomDiscovery discovery;
  late final List<StreamSubscription<Object?>> _subscriptions;

  /// dispose 之后异步收尾（关连接、隐藏悬浮窗）还会走到 notifyListeners，
  /// 直接调会命中 ChangeNotifier 的 use-after-dispose 断言。
  bool _disposed = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  List<MemberState> _members = const [];
  List<MemberState> get members => _members;
  BleSnapshot get ble => heartRate.snapshot;
  HeartRateSample? get sample => heartRate.latest;

  /// 当前还能当真读数的 BPM：超过断流阈值没有新采样就是 null，不沿用旧值。
  int? get liveBpm {
    final point = series.latest;
    if (point == null) return null;
    return series.isFreshAt(_clock()) ? point.bpm : null;
  }

  bool get overlayEnabled => _overlayEnabled;

  /// 背景不透明度（0 = 完全透明）。内容始终不透明，见 [OverlayDefaults]。
  double get overlayAlpha => _overlayAlpha;
  bool get overlayChart => _overlayChart;

  /// 悬浮窗当前是否真的在显示（权限被拒/服务没起来时为 false）。
  bool get overlayVisible => _overlayVisible;

  /// 自己当前生效的房间号：系统生成，用户不可编辑。
  String? get currentRoomCode {
    if (room.state == RoomConnectionState.connected &&
        room.roomCode != null &&
        room.roomCode!.isNotEmpty) {
      return room.roomCode;
    }
    return null;
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
    series.addSample(value);
    room.report(
      bpm: value.bpm,
      rrIntervalsMs: value.rrIntervalsMs,
      sensorContact: value.sensorContact,
      measuredAt: value.receivedAt,
    );
    _notify();
  }

  /// 远端/官方：连上去并记住这次配置。
  Future<void> connectProfile(
    ConnectionProfile profile, {
    String? roomCode,
  }) async {
    final effectiveRoom = (roomCode ?? profile.roomCode)?.trim();
    _mode = profile.mode;
    _notify();
    await room.connect(profile.toUri(roomCode: effectiveRoom));
    await _rememberProfile(profile.copyWith(roomCode: effectiveRoom));
  }

  Future<void> disconnectRoom() async {
    await room.disconnect();
    _mode = null;
    _notify();
  }

  /// 系统悬浮窗开关（用户主动动作，不自动申请）。偏好持久化；
  /// 权限被拒时只降级为不显示，不反复弹窗。
  Future<void> setOverlayEnabled(bool value) async {
    if (_overlayEnabled == value) return;
    _overlayEnabled = value;
    _notify();
    try {
      await _identity.saveOverlayEnabled(value);
    } catch (error, stack) {
      logger.error('app', 'Save overlay preference failed', null, error, stack);
    }
    await _syncOverlay();
  }

  /// 拖动中的透明度：只更新界面与已显示的窗口，不写盘。
  Future<void> previewOverlayAlpha(double value) async {
    final next = value.clamp(OverlayDefaults.minAlpha, 1.0).toDouble();
    if (next == _overlayAlpha) return;
    _overlayAlpha = next;
    _notify();
    if (_overlayVisible) await _overlayBackend.setAlpha(next);
  }

  /// 「显示折线图」开关：落盘并即时同步到已在显示的窗口（不用重开悬浮窗）。
  Future<void> setOverlayChart(bool value) async {
    if (_overlayChart == value) return;
    _overlayChart = value;
    _notify();
    logger.info(
      'overlay',
      'overlay chart=${value ? 'on' : 'off'}',
      code: 'overlay_chart',
    );
    try {
      await _identity.saveOverlayChart(value);
    } catch (error, stack) {
      logger.error('app', 'Save overlay chart failed', null, error, stack);
    }
    await _syncOverlay();
  }

  /// 松手后落盘（避免拖一次滑块写几十次偏好）。
  Future<void> setOverlayAlpha(double value) async {
    await previewOverlayAlpha(value);
    try {
      await _identity.saveOverlayAlpha(_overlayAlpha);
    } catch (error, stack) {
      logger.error('app', 'Save overlay alpha failed', null, error, stack);
    }
  }

  /// 用户主动开启悬浮窗时申请权限；只有这一步会打开系统授权页。
  Future<bool> ensureOverlayPermission() async {
    var granted = await _overlayBackend.isPermissionGranted();
    if (!granted) {
      await _overlayBackend.requestPermission();
      granted = await _overlayBackend.isPermissionGranted();
    }
    logger.info(
      'overlay',
      'overlay permission granted=$granted',
      code: 'overlay_permission',
    );
    return granted;
  }

  /// 用户在设置页点「重新尝试」：重新查权限并尝试开窗（不改偏好）。
  Future<void> retryOverlay() => _syncOverlay();

  /// 悬浮窗同步：串行化，避免并发下重复开窗；无房间/无权限时一律收掉。
  Future<void> _syncOverlay() {
    final next = _overlayQueue.then((_) => _syncOverlayOnce());
    _overlayQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _syncOverlayOnce() async {
    if (_disposed) return;
    final wantShown =
        _overlayEnabled && room.state == RoomConnectionState.connected;
    if (!wantShown) {
      if (!_overlayVisible) {
        _logOverlayState(
          _overlayEnabled ? 'hidden_no_room' : 'hidden_disabled',
        );
        return;
      }
      final hidden = await _overlayBackend.hide();
      // 收不掉（通道异常等）就保持"仍在显示"，下次同步再收，别留下僵尸窗口。
      _overlayVisible = !hidden;
      _logOverlayState(hidden ? 'hidden' : 'hide_failed');
      return;
    }
    final members = _overlayMembers();
    if (_overlayVisible) {
      // 原生侧返回 false = 窗口已经不在了（权限被撤销/服务停了），
      // 立刻把它当成"未显示"，下一次同步会重新尝试。
      _overlayVisible = await _overlayBackend.update(members);
      _logOverlayState(_overlayVisible ? 'shown' : 'lost', members.length);
      return;
    }
    if (_disposed) return;
    if (!await _overlayBackend.isPermissionGranted()) {
      _logOverlayState('no_permission');
      return;
    }
    final shown = await _overlayBackend.show(members, _overlayAlpha);
    if (_disposed) {
      // 期间被 dispose 了：把刚开出来的窗口撤掉，不留孤儿。
      if (shown) await _overlayBackend.hide();
      return;
    }
    _overlayVisible = shown;
    _logOverlayState(shown ? 'shown' : 'show_rejected', members.length);
  }

  /// 悬浮窗状态只在**变化**时写日志：同步每秒跑一次，逐次写会把会话日志灌满
  /// （早先正是这种噪声掩盖了真问题）。
  void _logOverlayState(String state, [int? members]) {
    if (_overlayState == state) return;
    _overlayState = state;
    final suffix = members == null ? '' : ' members=$members';
    logger.info(
      'overlay',
      'overlay state=$state$suffix',
      code: 'overlay_state',
    );
  }

  /// 把每个成员新收到的一次上报记进它自己的序列（同一秒重复/乱序的都丢掉）。
  void _trackMemberSamples() {
    final ids = <String>{};
    for (final member in _members) {
      final report = member.report;
      ids.add(report.memberId);
      if (!member.online) continue;
      final series = _memberSeries.putIfAbsent(
        report.memberId,
        HeartRateSeries.new,
      );
      final last = series.latest;
      if (last != null && !report.measuredAt.isAfter(last.at)) continue;
      series.add(HeartRatePoint(at: report.measuredAt, bpm: report.bpm));
    }
    // 离开房间的成员不再占内存。
    _memberSeries.removeWhere((id, _) => !ids.contains(id));
  }

  /// 悬浮窗一行：名称 + 心率 + 归一化小折线（关闭折线图或离线时为空）。
  List<OverlayMember> _overlayMembers() => [
    for (final member in _members) _overlayMember(member),
  ];

  OverlayMember _overlayMember(MemberState member) {
    final online = member.online;
    final polyline = _overlayChart && online
        ? overlayPolyline(_memberSeries[member.report.memberId])
        : (segments: const <List<double>>[], bridges: const <List<double>>[]);
    return OverlayMember(
      name: member.report.displayName,
      // 离线成员不保留旧 BPM：显示为空，由原生侧写"离线/无读数"。
      bpm: online ? member.report.bpm : null,
      online: online,
      points: polyline.segments,
      bridges: polyline.bridges,
    );
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
  /// 可能已经死掉且没有任何回调），必要时立刻重连；悬浮窗权限也可能被撤销。
  void onAppLifecycle(AppLifecycleState state) {
    logger.info('app', 'lifecycle=${state.name}', code: 'app_lifecycle');
    if (state == AppLifecycleState.resumed) {
      unawaited(room.onAppResumed());
      unawaited(_syncOverlay());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _overlayVisible = false;
    unawaited(_overlayBackend.hide());
    unawaited(room.dispose());
    unawaited(heartRate.dispose());
    unawaited(discovery.dispose());
    debug.dispose();
    super.dispose();
  }
}
