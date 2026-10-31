import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 前台服务桥接。
///
/// 只做一件事：在 BLE 已连接期间把进程钉在前台优先级，避免 targetSdk 36
/// 下息屏/切后台后被系统按后台进程回收而掐断 GATT。GATT 本身仍由
/// flutter_blue_plus 在主进程里持有，这里不碰 BLE。
///
/// 失败不致命：任何异常都退化成「没有前台服务」，只留一行日志。
final class HrsForeground {
  static const _channel = MethodChannel(
    'com.wjmagit.heartrateshare/foreground',
  );

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<bool> start() => _invoke('start');

  static Future<bool> stop() => _invoke('stop');

  static Future<bool> _invoke(String method) async {
    if (!_supported) return false;
    try {
      await _channel.invokeMethod<bool>(method);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
