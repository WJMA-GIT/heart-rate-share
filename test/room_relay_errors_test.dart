import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/l10n/strings_zh.dart';

void main() {
  group('服务端错误码 → 中文提示', () {
    test('ROOM_FULL 明确说房间满员（不再静默）', () {
      expect(Zh.relayError('ROOM_FULL'), contains('房间已满'));
      expect(Zh.relayError('ROOM_FULL'), contains('20'));
    });

    test('SERVER_FULL / BAD_MESSAGE 各有说法', () {
      expect(Zh.relayError('SERVER_FULL'), contains('服务器'));
      expect(Zh.relayError('BAD_MESSAGE'), contains('房间号'));
    });

    test('未知/空错误码不打扰用户', () {
      expect(Zh.relayError(null), isEmpty);
      expect(Zh.relayError('WHATEVER'), isEmpty);
    });
  });
}
