import 'dart:io';

import 'package:flutter/foundation.dart';

/// 桌面端启动/崩溃日志：和原生 runner 写同一个文件
/// （`%LOCALAPPDATA%\heartrate\logs\startup.log`），用户回传一个文件就够了。
abstract final class StartupLog {
  static File? _file;

  static File? get file => _file;

  /// 日志文件路径（给界面/错误提示用）。
  static String? get path => _file?.path;

  /// 阶段打点：每步一行，用户回传后一眼能看出卡在哪。
  static void stage(String name) => _write('stage: $name');

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
  /// 同一条错误每帧都会重放：只记第一次完整栈，之后每 100 次记一条计数。
  /// （1.0.5 的 startup.log 被 75 条同样的 Null-check 栈刷到 1.8 MB。）
  static final Map<String, int> _seen = {};

  static void installHandlers() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final signature = details.exceptionAsString();
      final count = (_seen[signature] ?? 0) + 1;
      _seen[signature] = count;
      if (count == 1) {
        _write('dart: FlutterError $signature');
        final stack = '${details.stack ?? ''}';
        _write(
          stack.length > 4000
              ? '${stack.substring(0, 4000)}…(truncated)'
              : stack,
        );
      } else if (count % 100 == 0) {
        _write('dart: FlutterError repeated $count times: $signature');
      }
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
