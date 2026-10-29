import 'dart:io';

import '../core/config/app_config.dart';
import 'room_code.dart';

enum RoomAddressError {
  empty,
  unsupportedScheme,
  invalidHost,
  invalidPort,
  invalidRoomCode,

  /// 官方服务器只走 wss：显式写了 ws:// 属于配置错误，必须纠正而不是照发。
  insecureScheme,
}

final class RoomAddressException implements FormatException {
  const RoomAddressException(this.reason);

  final RoomAddressError reason;

  @override
  String get message => switch (reason) {
    RoomAddressError.empty => 'Address is empty',
    RoomAddressError.unsupportedScheme => 'Expected ws://, wss://, host or IP',
    RoomAddressError.invalidHost => 'Invalid host',
    RoomAddressError.invalidPort => 'Invalid port',
    RoomAddressError.invalidRoomCode => 'Invalid room code',
    RoomAddressError.insecureScheme => 'Official server requires wss://',
  };

  @override
  int? get offset => null;

  @override
  dynamic get source => null;

  @override
  String toString() => 'RoomAddressException(${reason.name}): $message';
}

final class RoomAddress {
  const RoomAddress._();

  /// 规范化成可直接粘贴回服务器地址框的端点：
  /// 保留协议与显式端口，去掉 `/ws` 路径、查询参数和房间号。
  static String normalizedEndpoint(String input) {
    final uri = parse(input);
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port).toString();
  }

  /// IPv6 字面量在 URL 里必须加方括号；裸的 `::1` 直接拼会得到非法 URL。
  static String bracket(String host) =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  static Uri parse(String input, {String? roomCode}) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const RoomAddressException(RoomAddressError.empty);
    }
    // 支持裸 IPv6 字面量（如 `fe80::1`、`::1`）：补方括号再按 URL 解析。
    if (!trimmed.contains('://') &&
        InternetAddress.tryParse(trimmed)?.type == InternetAddressType.IPv6) {
      trimmed = 'ws://[${trimmed.replaceAll('[', '').replaceAll(']', '')}]';
    }

    // 裸主机名默认明文（本机/局域网场景），但显式 :443 一定是要加密的 ——
    // 否则明文打到 443 只会失败。这类输入纠正而不是报错。
    final looksSecure =
        !trimmed.contains('://') && RegExp(r':443(/|$)').hasMatch(trimmed);
    final withScheme = trimmed.contains('://')
        ? trimmed
        : '${looksSecure ? 'wss' : 'ws'}://$trimmed';
    final authority = withScheme.split('://').last.split('/').first;
    final hostAndPort = authority.split('?').first;
    final colon = hostAndPort.lastIndexOf(':');
    if (colon >= 0 && !hostAndPort.startsWith('[')) {
      final portText = hostAndPort.substring(colon + 1);
      final port = int.tryParse(portText);
      if (port == null || port < 1 || port > 65535) {
        throw const RoomAddressException(RoomAddressError.invalidPort);
      }
    }

    final Uri base;
    try {
      base = Uri.parse(withScheme);
    } on FormatException {
      throw const RoomAddressException(RoomAddressError.invalidHost);
    }

    if (base.scheme != 'ws' && base.scheme != 'wss') {
      throw const RoomAddressException(RoomAddressError.unsupportedScheme);
    }
    if (base.host.isEmpty ||
        base.host.contains(RegExp(r'\s')) ||
        base.userInfo.isNotEmpty) {
      throw const RoomAddressException(RoomAddressError.invalidHost);
    }
    if (base.hasPort && (base.port < 1 || base.port > 65535)) {
      throw const RoomAddressException(RoomAddressError.invalidPort);
    }

    final port = base.hasPort
        ? base.port
        : base.scheme == 'wss'
        ? AppConfig.defaultSecureWebSocketPort
        : AppConfig.defaultWebSocketPort;

    if (roomCode != null &&
        roomCode.trim().isNotEmpty &&
        !RoomCode.isValid(roomCode)) {
      throw const RoomAddressException(RoomAddressError.invalidRoomCode);
    }
    final query = <String, String>{
      ...base.queryParameters,
      if (roomCode != null && roomCode.trim().isNotEmpty)
        'room': roomCode.trim(),
    };
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: port,
      path: AppConfig.webSocketPath,
      queryParameters: query.isEmpty ? null : query,
    );
  }
}

/// 解析**必须加密**的服务器地址（官方服务器 / 注入的 DEFAULT_SERVER）。
///
/// 规则：
/// - 裸主机名 → 补成 `wss://`（这是纠正：`RoomAddress.parse` 会补 `ws://`，
///   打到 443 必然失败）；
/// - 显式写了 `ws://` → 直接报 `insecureScheme`，让配置错误立刻暴露；
/// - 其余交给 [parse]。
abstract final class SecureEndpoint {
  static Uri parse(String input, {String? roomCode}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const RoomAddressException(RoomAddressError.empty);
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('ws://')) {
      throw const RoomAddressException(RoomAddressError.insecureScheme);
    }
    final withScheme = lower.startsWith('wss://') ? trimmed : 'wss://$trimmed';
    return RoomAddress.parse(withScheme, roomCode: roomCode);
  }
}
