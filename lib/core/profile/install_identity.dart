import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/room_overlay.dart';

/// 这台设备的**安装标识**：首次启动生成一次，之后一直复用。
///
/// 语义边界（写清楚是为了不让它以后被当成账号用）：
/// - 它是"这次安装"，不是"这个人"。重装 App / 清数据 → 新标识 → 服务端视为
///   新成员（旧成员 5 秒后离线、2 分钟后移除）。
/// - 换手机 → 新标识 → 新成员。"跨设备同一身份"需要账号体系，本版明确不做。
///
/// 它不参与鉴权：谁拿到这个字符串谁就能顶替该成员（ws:// 明文，本来就没有
/// 认证）。因此它是**去重标识**，不是凭证 —— 协议文档里也这么写。
abstract interface class IdentityStore {
  Future<String?> loadInstallId();
  Future<void> saveInstallId(String installId);

  /// 已预留的序号上界（见 `SequenceCounter`）。
  Future<int> loadReservedSequence();
  Future<void> saveReservedSequence(int reservedUpTo);

  /// 最近连接配置（JSON）。与安装标识共用同一套存储，不另起一套。
  Future<String?> loadConnectionProfiles();
  Future<void> saveConnectionProfiles(String blob);

  /// 系统悬浮窗偏好：开关 + 背景不透明度 + 显示折线图（都跟着安装走，
  /// 重连/重启后按偏好恢复）。
  Future<bool> loadOverlayEnabled();
  Future<void> saveOverlayEnabled(bool enabled);
  Future<double> loadOverlayAlpha();
  Future<void> saveOverlayAlpha(double alpha);
  Future<bool> loadOverlayChart();
  Future<void> saveOverlayChart(bool show);

  /// 「投射到局域网」：开关（默认开启）+ 房间码。跟着安装走。
  Future<bool> loadLanEnabled();
  Future<void> saveLanEnabled(bool enabled);
  Future<String?> loadLanRoom();
  Future<void> saveLanRoom(String room);
}

/// 生成 / 解析安装标识。
abstract final class InstallId {
  /// UUID v4 的字符串形式，128 位随机，无需联网、不含设备隐私信息。
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// 服务端把 memberId 当不透明短字符串（≤128）；这里做保守校验，
  /// 避免把损坏的本地值发上去导致每次进房都被判 BAD_MESSAGE。
  static bool isValid(String? value) {
    if (value == null) return false;
    final trimmed = value.trim();
    if (trimmed.length < 8 || trimmed.length > 128) return false;
    return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(trimmed);
  }
}

final class InMemoryIdentityStore implements IdentityStore {
  InMemoryIdentityStore({
    this.installId,
    this.reservedSequence = 0,
    this.connectionProfiles,
    this.overlayEnabled = false,
    this.overlayAlpha = OverlayDefaults.defaultAlpha,
    this.overlayChart = OverlayDefaults.defaultShowChart,
    this.lanEnabled = true,
    this.lanRoom,
  });

  String? installId;
  int reservedSequence;
  String? connectionProfiles;
  bool overlayEnabled;
  double overlayAlpha;
  bool overlayChart;
  bool lanEnabled;
  String? lanRoom;

  @override
  Future<String?> loadInstallId() async => installId;

  @override
  Future<void> saveInstallId(String value) async => installId = value;

  @override
  Future<int> loadReservedSequence() async => reservedSequence;

  @override
  Future<void> saveReservedSequence(int value) async =>
      reservedSequence = value;

  @override
  Future<String?> loadConnectionProfiles() async => connectionProfiles;

  @override
  Future<void> saveConnectionProfiles(String blob) async =>
      connectionProfiles = blob;

  @override
  Future<bool> loadOverlayEnabled() async => overlayEnabled;

  @override
  Future<void> saveOverlayEnabled(bool enabled) async =>
      overlayEnabled = enabled;

  @override
  Future<double> loadOverlayAlpha() async => overlayAlpha;

  @override
  Future<void> saveOverlayAlpha(double alpha) async => overlayAlpha = alpha;

  @override
  Future<bool> loadOverlayChart() async => overlayChart;

  @override
  Future<void> saveOverlayChart(bool show) async => overlayChart = show;

  @override
  Future<bool> loadLanEnabled() async => lanEnabled;

  @override
  Future<void> saveLanEnabled(bool enabled) async => lanEnabled = enabled;

  @override
  Future<String?> loadLanRoom() async => lanRoom;

  @override
  Future<void> saveLanRoom(String room) async => lanRoom = room;
}

final class SharedPreferencesIdentityStore implements IdentityStore {
  SharedPreferencesIdentityStore(this._preferences);

  static const installIdKey = 'identity.installId';
  static const reservedSequenceKey = 'room.reservedSequence';
  static const connectionProfilesKey = 'connection.recentProfiles';
  static const overlayEnabledKey = 'overlay.enabled';
  static const overlayAlphaKey = 'overlay.alpha';
  static const overlayChartKey = 'overlay.chart';
  static const lanEnabledKey = 'lan.enabled';
  static const lanRoomKey = 'lan.room';

  final SharedPreferences _preferences;

  @override
  Future<String?> loadInstallId() async => _preferences.getString(installIdKey);

  @override
  Future<void> saveInstallId(String installId) async {
    final ok = await _preferences.setString(installIdKey, installId);
    if (!ok) throw StateError('installId persistence failed');
  }

  @override
  Future<int> loadReservedSequence() async =>
      _preferences.getInt(reservedSequenceKey) ?? 0;

  @override
  Future<void> saveReservedSequence(int reservedUpTo) async {
    final ok = await _preferences.setInt(reservedSequenceKey, reservedUpTo);
    if (!ok) throw StateError('sequence persistence failed');
  }

  @override
  Future<String?> loadConnectionProfiles() async =>
      _preferences.getString(connectionProfilesKey);

  @override
  Future<void> saveConnectionProfiles(String blob) async {
    final ok = await _preferences.setString(connectionProfilesKey, blob);
    if (!ok) throw StateError('profile persistence failed');
  }

  @override
  Future<bool> loadOverlayEnabled() async =>
      _preferences.getBool(overlayEnabledKey) ?? false;

  @override
  Future<void> saveOverlayEnabled(bool enabled) async {
    final ok = await _preferences.setBool(overlayEnabledKey, enabled);
    if (!ok) throw StateError('overlay preference persistence failed');
  }

  @override
  Future<double> loadOverlayAlpha() async =>
      _preferences.getDouble(overlayAlphaKey) ?? OverlayDefaults.defaultAlpha;

  @override
  Future<void> saveOverlayAlpha(double alpha) async {
    final ok = await _preferences.setDouble(overlayAlphaKey, alpha);
    if (!ok) throw StateError('overlay alpha persistence failed');
  }

  @override
  Future<bool> loadOverlayChart() async =>
      _preferences.getBool(overlayChartKey) ?? OverlayDefaults.defaultShowChart;

  @override
  Future<void> saveOverlayChart(bool show) async {
    final ok = await _preferences.setBool(overlayChartKey, show);
    if (!ok) throw StateError('overlay chart persistence failed');
  }

  @override
  Future<bool> loadLanEnabled() async =>
      _preferences.getBool(lanEnabledKey) ?? true; // 默认开启

  @override
  Future<void> saveLanEnabled(bool enabled) async {
    final ok = await _preferences.setBool(lanEnabledKey, enabled);
    if (!ok) throw StateError('lan preference persistence failed');
  }

  @override
  Future<String?> loadLanRoom() async => _preferences.getString(lanRoomKey);

  @override
  Future<void> saveLanRoom(String room) async {
    final ok = await _preferences.setString(lanRoomKey, room);
    if (!ok) throw StateError('lan room persistence failed');
  }
}
