import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/profile/nickname.dart';
import 'package:heartrate/core/profile/user_profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Nickname', () {
    test('accepts Chinese and trims surrounding whitespace', () {
      expect(Nickname.validate('  阿城  '), isNull);
      expect(Nickname.normalize('  阿城  '), '阿城');
    });

    test('accepts 1 and 16 visible characters', () {
      expect(Nickname.validate('A'), isNull);
      expect(Nickname.validate('一二三四五六七八九十一二三四五六'), isNull);
    });

    test('rejects empty and more than 16 characters', () {
      expect(Nickname.validate('   '), NicknameValidationError.empty);
      expect(Nickname.validate('一二三四五六七八九十一二三四五六七'),
          NicknameValidationError.tooLong);
    });
  });

  testWidgets('shared preferences persists nickname', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = SharedPreferencesUserProfileStore(preferences);
    expect(await store.loadNickname(), isNull);
    await store.saveNickname('阿城');
    expect(await store.loadNickname(), '阿城');
  });
}
