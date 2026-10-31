import 'package:package_info_plus/package_info_plus.dart';

/// 版本号**唯一**读取入口：`pubspec.yaml` 的 `version:` 是唯一真源。
///
/// - Android：构建把 `versionName` 写进 APK，这里用 `PackageInfo` 读回来；
/// - Windows：Flutter 把同一份 `version` 写进 exe 的版本资源，`PackageInfo` 从文件属性读回；
/// - 兜底：`--dart-define=APP_VERSION=…`（CI 传），再不行返回 `0.0.0`。
///
/// 任何地方**不要**再手写 `'1.0.x'` 字面量——`flutter-ci.yml` 有门禁会扫出来。
final class AppVersion {
  static String? _cached;

  static Future<String> read() async {
    final cached = _cached;
    if (cached != null) return cached;
    String value;
    try {
      final info = await PackageInfo.fromPlatform();
      value = info.version.isEmpty ? '0.0.0' : info.version;
    } catch (_) {
      value = const String.fromEnvironment(
        'APP_VERSION',
        defaultValue: '0.0.0',
      );
    }
    if (value == '0.0.0') {
      final injected = const String.fromEnvironment('APP_VERSION');
      if (injected.isNotEmpty) value = injected;
    }
    _cached = value;
    return value;
  }

  /// 展示用：`1.0.11`（不含 build number；需要时用 [readWithBuild]）。
  static Future<String> readWithBuild() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return read();
    }
  }
}
