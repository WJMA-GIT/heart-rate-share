import 'dart:convert';

import '../config/app_config.dart';
import '../../room/room_address.dart';

/// 房间连接方式。二选一是**显式**的：没有隐式默认，必须由用户选择。
///
/// 本机建房（原 `local`）已随"只保留创建/加入两个动作"一起删除；历史里可能
/// 还留着 `mode: local` 的旧记录，解码时那个值已不存在 → 整条记录被丢弃，
/// 不会被当成可连接的目标。
enum ConnectionMode {
  /// 官方服务器（默认 wss://mawj.asia:8766）。
  official,

  /// 用户自填的远程服务器。
  remote,
}

/// 一份「连接配置」：能直接点一下就重连的全部信息。
final class ConnectionProfile {
  const ConnectionProfile({
    required this.mode,
    required this.host,
    required this.port,
    required this.secure,
    this.roomCode,
    this.lastUsedAt,
    this.path = '/ws',
  });

  /// 官方服务器：`wss://relay.mawj.asia`（443），可被 --dart-define=DEFAULT_SERVER 覆盖。
  /// 裸主机名会被纠正成 wss；显式写 ws:// 会抛异常，避免明文打到 443。
  factory ConnectionProfile.official({String? roomCode}) =>
      ConnectionProfile.fromEndpoint(
        AppConfig.effectiveOfficialServer,
        mode: ConnectionMode.official,
        roomCode: roomCode,
      );

  /// 备用线路：只有注入 `--dart-define=SECONDARY_SERVER=...` 时才存在，
  /// 未配置返回 null（界面据此隐藏备用按钮，不凭空给一个死地址）。
  static ConnectionProfile? officialSecondary({String? roomCode}) {
    final endpoint = AppConfig.effectiveSecondaryServer;
    if (endpoint == null) return null;
    return ConnectionProfile.fromEndpoint(
      endpoint,
      mode: ConnectionMode.official,
      roomCode: roomCode,
    );
  }

  /// 从「可能没写协议」的地址构造：官方/备用都走 [SecureEndpoint] 强制 wss。
  factory ConnectionProfile.fromEndpoint(
    String endpoint, {
    ConnectionMode mode = ConnectionMode.remote,
    String? roomCode,
  }) {
    final uri = SecureEndpoint.parse(endpoint);
    return ConnectionProfile(
      mode: mode,
      host: uri.host,
      port: uri.port,
      secure: uri.scheme == 'wss',
      roomCode: roomCode,
      path: uri.path.isEmpty ? '/ws' : uri.path,
    );
  }

  final ConnectionMode mode;
  final String host;
  final int port;
  final bool secure;
  final String? roomCode;
  final DateTime? lastUsedAt;

  /// 握手路径，默认 `/ws`。DEFAULT_SERVER 里带了别的路径时以它为准。
  final String path;

  String get scheme => secure ? 'wss' : 'ws';

  /// 稳定主键：按端点区分。
  String get id => '${mode.name}|$scheme://$host:$port';

  /// 端点字符串。**只在设置/调试/诊断里展示**，主界面不露出。
  /// IPv6 字面量必须方括号括起，否则拼出来的 URL 是错的。
  String get endpoint {
    final literal = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    // wss 的 443 是协议默认值，不重复展示（用户看到的是 wss://relay.mawj.asia）。
    final showPort = !(secure && port == 443);
    return showPort ? '$scheme://$literal:$port' : '$scheme://$literal';
  }

  ConnectionProfile copyWith({
    String? roomCode,
    DateTime? lastUsedAt,
    int? port,
  }) => ConnectionProfile(
    mode: mode,
    host: host,
    port: port ?? this.port,
    secure: secure,
    roomCode: roomCode ?? this.roomCode,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    path: path,
  );

  /// 生成实际连接用的 URI。[portOverride] 用于测试与端口转发。
  /// 拼出 `/ws?room=<短码>`。房间号先按 `^[A-Za-z0-9_-]{1,64}$` 校验，
  /// 非法就直接抛，避免拿着 400/404 回来再猜。
  Uri toUri({String? roomCode, int? portOverride}) {
    final effectivePort = portOverride ?? port;
    final code = roomCode ?? this.roomCode;
    final includePort = effectivePort > 0 && !(secure && effectivePort == 443);
    final query = <String, String>{
      if (code != null && code.trim().isNotEmpty) 'room': code.trim(),
    };
    return Uri(
      scheme: scheme,
      host: host,
      port: includePort ? effectivePort : null,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'host': host,
    'port': port,
    'secure': secure,
    'path': path,
    'roomCode': roomCode,
    'lastUsedAt': lastUsedAt?.toUtc().toIso8601String(),
  };

  static ConnectionProfile? fromJson(Map<String, Object?> json) {
    final mode = ConnectionMode.values.asNameMap()[json['mode']];
    final host = json['host'];
    final port = json['port'];
    final secure = json['secure'];
    if (mode == null || host is! String || host.isEmpty) return null;
    if (port is! int || port < 0 || port > 65535) return null;
    if (secure is! bool) return null;
    final room = json['roomCode'];
    final used = json['lastUsedAt'];
    return ConnectionProfile(
      mode: mode,
      host: host,
      port: port,
      secure: secure,
      roomCode: room is String && room.trim().isNotEmpty ? room.trim() : null,
      path: json['path'] is String && (json['path'] as String).isNotEmpty
          ? json['path'] as String
          : '/ws',
      lastUsedAt: used is String ? DateTime.tryParse(used)?.toUtc() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionProfile && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// 「最近连接」列表的纯逻辑：去重、置顶、裁剪。便于单测，不碰存储与网络。
abstract final class RecentProfiles {
  static const maxEntries = 6;

  /// 把 [used] 插入列表：同 id 覆盖（保留新的 roomCode），置顶，最多 [maxEntries] 条。
  static List<ConnectionProfile> touch(
    List<ConnectionProfile> current,
    ConnectionProfile used, {
    DateTime? now,
  }) {
    final stamped = used.copyWith(lastUsedAt: now ?? DateTime.now().toUtc());
    final rest = current.where((profile) => profile.id != stamped.id);
    final merged = [stamped, ...rest].toList()
      ..sort((a, b) {
        final left = a.lastUsedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.lastUsedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    return merged.take(maxEntries).toList();
  }

  static String encode(List<ConnectionProfile> profiles) =>
      jsonEncode(profiles.map((profile) => profile.toJson()).toList());

  /// 解码时容忍脏数据：单条坏了就跳过，不让整份最近列表消失。
  static List<ConnectionProfile> decode(String? blob) {
    if (blob == null || blob.trim().isEmpty) return const [];
    try {
      final raw = jsonDecode(blob);
      if (raw is! List) return const [];
      final parsed = <ConnectionProfile>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final profile = ConnectionProfile.fromJson(
          item.map((key, value) => MapEntry('$key', value)),
        );
        if (profile != null) parsed.add(profile);
      }
      return parsed.take(maxEntries).toList();
    } on FormatException {
      return const [];
    }
  }
}
