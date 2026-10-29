/// 房间短码规则：`^[A-Za-z0-9_-]{1,64}$`。
///
/// 与服务端一致（`server/src/relay.js` 的 `MAX_ROOM_CODE_LEN=64`，只接受这个
/// 字符集）。客户端先校验，可以避免把非法房间号拼进 URL 后拿到 400/404 ——
/// 那种失败在界面上很难解释。
abstract final class RoomCode {
  static final _pattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static const maxLength = 64;

  static bool isValid(String? value) {
    if (value == null) return false;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    return _pattern.hasMatch(trimmed);
  }

  /// 合法则返回去空白后的值，否则 null。
  static String? normalize(String? value) {
    if (!isValid(value)) return null;
    return value!.trim();
  }
}
