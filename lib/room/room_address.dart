import '../core/config/app_config.dart';

enum RoomAddressError { empty, unsupportedScheme, invalidHost, invalidPort }

final class RoomAddressException implements FormatException {
  const RoomAddressException(this.reason);

  final RoomAddressError reason;

  @override
  String get message => switch (reason) {
    RoomAddressError.empty => 'Address is empty',
    RoomAddressError.unsupportedScheme => 'Expected ws://, wss://, host or IP',
    RoomAddressError.invalidHost => 'Invalid host',
    RoomAddressError.invalidPort => 'Invalid port',
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

  static Uri parse(String input, {String? roomCode}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const RoomAddressException(RoomAddressError.empty);
    }

    final withScheme = trimmed.contains('://') ? trimmed : 'ws://$trimmed';
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
