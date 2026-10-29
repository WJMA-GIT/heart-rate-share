import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

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
  });

  String? installId;
  int reservedSequence;
  String? connectionProfiles;

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
}

final class SharedPreferencesIdentityStore implements IdentityStore {
  SharedPreferencesIdentityStore(this._preferences);

  static const installIdKey = 'identity.installId';
  static const reservedSequenceKey = 'room.reservedSequence';
  static const connectionProfilesKey = 'connection.recentProfiles';

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
}
