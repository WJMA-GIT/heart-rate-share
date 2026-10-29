import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Generates non-credential identifiers and short room codes.
/// Current ws:// MVP transport is explicitly development-only.
final class RoomIdentity {
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static String shortCode({int length = 6}) {
    final random = Random.secure();
    return List.generate(length, (_) => _alphabet[random.nextInt(_alphabet.length)]).join();
  }

  static String memberId() {
    final bytes = Uint8List(16);
    final random = Random.secure();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

}
