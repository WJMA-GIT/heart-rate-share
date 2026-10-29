import 'dart:convert';

/// 房间连接方式。三选一是**显式**的：没有隐式默认，必须由用户选择。
enum ConnectionMode {
  /// 官方服务器（默认 wss://mawj.asia:8766）。
  official,

  /// 用户自填的远程服务器。
  remote,

  /// 在本机起 Relay 再自己连上去（不需要加密）。
  local,
}

/// 一份「连接配置」：能直接点一下就重连的全部信息。
///
/// 本机房间的端口是每次启动重新分配的，所以 [port] 为 0 表示「运行时再定」，
/// 且它的 id 固定为 `local`——不会因为端口变化把最近列表刷出一串无效项。
final class ConnectionProfile {
  const ConnectionProfile({
    required this.mode,
    required this.host,
    required this.port,
    required this.secure,
    this.roomCode,
    this.lastUsedAt,
  });

  factory ConnectionProfile.official({String? roomCode}) => ConnectionProfile(
    mode: ConnectionMode.official,
    host: 'mawj.asia',
    port: 8766,
    secure: true,
    roomCode: roomCode,
  );

  factory ConnectionProfile.local() => const ConnectionProfile(
    mode: ConnectionMode.local,
    host: '127.0.0.1',
    port: 0,
    secure: false,
  );

  final ConnectionMode mode;
  final String host;
  final int port;
  final bool secure;
  final String? roomCode;
  final DateTime? lastUsedAt;

  String get scheme => secure ? 'wss' : 'ws';

  /// 稳定主键：官方/自填按端点区分，本机只有一个。
  String get id => switch (mode) {
    ConnectionMode.local => 'local',
    _ => '${mode.name}|$scheme://$host:$port',
  };

  /// 端点字符串。**只在设置/调试/诊断里展示**，主界面不露出。
  /// IPv6 字面量必须方括号括起，否则拼出来的 URL 是错的。
  String get endpoint {
    final literal = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return switch (mode) {
      ConnectionMode.local => 'ws://$literal:<本机端口>',
      _ => '$scheme://$literal:$port',
    };
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
  );

  /// 生成实际连接用的 URI。[portOverride] 用于本机房间的运行时端口。
  Uri toUri({String? roomCode, int? portOverride}) {
    final effectivePort = portOverride ?? port;
    return Uri(
      scheme: scheme,
      host: host,
      port: effectivePort <= 0 ? null : effectivePort,
      path: '/ws',
      queryParameters: {
        if ((roomCode ?? this.roomCode)?.trim().isNotEmpty ?? false)
          'room': (roomCode ?? this.roomCode)!.trim(),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'host': host,
    'port': port,
    'secure': secure,
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
