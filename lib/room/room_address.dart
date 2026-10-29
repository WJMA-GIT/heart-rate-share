import '../core/config/app_config.dart';

final class RoomAddress {
  const RoomAddress._();
  static Uri parse(String input, {String? roomCode}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) throw const FormatException('Address is empty');
    final withScheme = trimmed.contains('://') ? trimmed : 'ws://$trimmed';
    final base = Uri.parse(withScheme);
    if ((base.scheme != 'ws' && base.scheme != 'wss') || base.host.isEmpty) {
      throw const FormatException('Expected ws://host:port');
    }
    return base.replace(
      port: base.hasPort ? base.port : AppConfig.defaultWebSocketPort,
      path: AppConfig.webSocketPath,
      queryParameters: {
        if (roomCode != null && roomCode.trim().isNotEmpty)
          'room': roomCode.trim(),
        ...base.queryParameters,
      },
    );
  }
}
