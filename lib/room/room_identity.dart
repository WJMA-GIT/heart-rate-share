import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Generates non-credential identifiers.
/// Current ws:// MVP transport is explicitly development-only.
///
/// 房间短码不在这里生成：唯一来源是 `RoomCode.generate()`（`lib/room/room_code.dart`），
/// 本机建房删除后不应再有第二份生成逻辑。
final class RoomIdentity {
  static String memberId() {
    final bytes = Uint8List(16);
    final random = Random.secure();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
