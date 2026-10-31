import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个 APK 的静态信息（由系统 PackageManager 解析，不执行里面的代码）。
final class ApkInfo {
  const ApkInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.signerSha256,
    required this.sameSignerAsThisApp,
  });

  final String packageName;
  final int versionCode;
  final String versionName;

  /// 签名证书 SHA-256（十六进制，小写）；解析不到时为空串。
  final String signerSha256;

  /// 是否与本机已装版本的签名一致（覆盖安装的前提）。
  final bool sameSignerAsThisApp;
}

/// 安装相关的平台桥（可替换，便于单测）。
abstract interface class UpdateInstaller {
  /// 本机首选 ABI：`arm64-v8a` / `armeabi-v7a` / `x86_64` / `unknown`。
  Future<String> deviceAbi();

  /// 解析 APK 的包名/版本/签名；文件不是合法 APK 时返回 null。
  Future<ApkInfo?> inspectApk(String path);

  /// 是否已允许"安装未知应用"。
  Future<bool> canInstall();

  /// 打开系统的"安装未知应用"授权页。
  Future<bool> openInstallSettings();

  /// 拉起系统安装器（**必须由用户确认**，不做静默安装）。
  Future<bool> install(String path);

  /// 用外部浏览器打开链接（失败兜底）。
  Future<bool> openUrl(String url);
}

/// Android 实现：`MethodChannel('com.wjmagit.heartrateshare/update')`。
final class PlatformUpdateInstaller implements UpdateInstaller {
  const PlatformUpdateInstaller();

  static const channel = MethodChannel('com.wjmagit.heartrateshare/update');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!supported) return null;
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String> deviceAbi() async =>
      (await _invoke<String>('abi')) ?? 'unknown';

  @override
  Future<ApkInfo?> inspectApk(String path) async {
    final raw = await _invoke<Map<Object?, Object?>>('inspectApk', {
      'path': path,
    });
    if (raw == null) return null;
    final packageName = raw['packageName'];
    if (packageName is! String) return null;
    return ApkInfo(
      packageName: packageName,
      versionCode: (raw['versionCode'] as num?)?.toInt() ?? 0,
      versionName: (raw['versionName'] as String?) ?? '',
      signerSha256: (raw['signerSha256'] as String?) ?? '',
      sameSignerAsThisApp: raw['sameSignerAsThisApp'] == true,
    );
  }

  @override
  Future<bool> canInstall() async =>
      (await _invoke<bool>('canInstall')) ?? false;

  @override
  Future<bool> openInstallSettings() async =>
      (await _invoke<bool>('openInstallSettings')) ?? false;

  @override
  Future<bool> install(String path) async =>
      (await _invoke<bool>('install', {'path': path})) ?? false;

  @override
  Future<bool> openUrl(String url) async =>
      (await _invoke<bool>('openUrl', {'url': url})) ?? false;
}
