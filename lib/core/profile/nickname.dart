import 'package:characters/characters.dart';

enum NicknameValidationError { empty, tooLong }

abstract final class Nickname {
  static const minLength = 1;
  static const maxLength = 16;

  /// 以用户可见字符（字素簇）计数，中文、emoji 都按 1 个字符计算。
  static NicknameValidationError? validate(String input) {
    final value = normalize(input);
    if (value.characters.length < minLength) {
      return NicknameValidationError.empty;
    }
    if (value.characters.length > maxLength) {
      return NicknameValidationError.tooLong;
    }
    return null;
  }

  static String normalize(String input) => input.trim();
}
