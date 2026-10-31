import 'package:shared_preferences/shared_preferences.dart';

abstract interface class UserProfileStore {
  Future<String?> loadNickname();
  Future<void> saveNickname(String nickname);
}

final class InMemoryUserProfileStore implements UserProfileStore {
  InMemoryUserProfileStore([this._nickname]);
  String? _nickname;

  @override
  Future<String?> loadNickname() async => _nickname;

  @override
  Future<void> saveNickname(String nickname) async => _nickname = nickname;
}

final class SharedPreferencesUserProfileStore implements UserProfileStore {
  SharedPreferencesUserProfileStore(this._preferences);
  static const _nicknameKey = 'profile.nickname';
  final SharedPreferences _preferences;

  @override
  Future<String?> loadNickname() async => _preferences.getString(_nicknameKey);

  @override
  Future<void> saveNickname(String nickname) async {
    final saved = await _preferences.setString(_nicknameKey, nickname);
    if (!saved) {
      throw StateError('Nickname persistence failed');
    }
  }
}
