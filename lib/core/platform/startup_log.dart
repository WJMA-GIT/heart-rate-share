import 'dart:io';

import 'package:flutter/foundation.dart';

/// 桌面端启动/崩溃日志：和原生 runner 写同一个文件
/// （`%LOCALAPPDATA%\heartrate\logs\startup.log`），用户回传一个文件就够了。
abstract final class StartupLog {
  static File? _file;

  static File? get file => _file;

  static void attach({required String platform}) {
    if (kIsWeb) return;
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    try {
      final base =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory(
        '$base${Platform.pathSeparator}heartrate${Platform.pathSeparator}logs',
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}${Platform.pathSeparator}startup.log');
      _write('dart: startup attach platform=$platform version=${_version()}');
    } catch (_) {
      _file = null;
    }
  }

  static String _version() {
    try {
      return Platform.resolvedExecutable;
    } catch (_) {
      return 'unknown';
    }
  }

  static void _write(String line) {
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志写不进去也不能影响启动
    }
  }

  /// 接住 Dart 侧的未捕获异常：写同一份日志，并保留默认错误上报。
  static void installHandlers() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      _write('dart: FlutterError ${details.exceptionAsString()}');
      _write('${details.stack ?? ''}');
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _write('dart: uncaught $error');
      _write('$stack');
      return true;
    };
  }

  static void info(String message) => _write('dart: $message');
}
