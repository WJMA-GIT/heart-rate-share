import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/app_config.dart';
import '../l10n/strings_zh.dart';

enum LogLevel { debug, info, warn, error }

final class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.module,
    required this.message,
    this.deviceId,
    this.errorCode,
    this.stack,
  });
  final DateTime at;
  final LogLevel level;
  final String module;
  final String message;
  final String? deviceId;
  final String? errorCode;
  final String? stack;

  String format() {
    final device = deviceId == null ? '-' : LogSanitizer.device(deviceId!);
    final code = errorCode ?? '-';
    final tail = stack == null ? '' : '\n$stack';
    return '${at.toUtc().toIso8601String()} ${level.name.toUpperCase()} '
        '[$module] device=$device code=$code $message$tail';
  }
}

abstract final class LogSanitizer {
  static final _secretKey = RegExp(
    r'(token|secret|password|authorization|api[_-]?key|pairing[_-]?key)(\s*[:=]\s*)\S+',
    caseSensitive: false,
  );
  static String text(String input) => input.replaceAllMapped(
    _secretKey,
    (match) => '${match[1]}${match[2]}[REDACTED]',
  );
  static String device(String input) =>
      input.length <= 8 ? input : '…${input.substring(input.length - 8)}';
}

/// Bounded in-memory diagnostics plus one local file per app session.
/// Logs are diagnostic, not an audit trail. Network message payloads are never
/// logged because a room token could appear in them.
final class AppLogger {
  AppLogger._();
  static final instance = AppLogger._();
  final _entries = <LogEntry>[];
  final _changes = StreamController<void>.broadcast();
  final _sessionId = DateTime.now().toUtc().toIso8601String().replaceAll(
    ':',
    '-',
  );
  bool debugEnabled = false;
  bool _initialized = false;
  File? _file;
  Future<void> _writeQueue = Future.value();

  Stream<void> get changes => _changes.stream;
  List<LogEntry> get entries => List.unmodifiable(_entries);
  String get sessionId => _sessionId;
  String? get filePath => _file?.path;

  /// [version] 是 `versionName+versionBuild`（由 `package_info_plus` 提供）。
  /// 之前这里只打 applicationId，导致导出日志里**看不出装的是哪一版** ——
  /// 排查真机问题时这是第一条要确认的信息。
  Future<void> initialize({String version = ''}) async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    final Directory root;
    if (Platform.isAndroid) {
      // App-specific external storage: no broad storage permission required.
      root =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else if (Platform.isIOS) {
      root = await getApplicationDocumentsDirectory();
    } else {
      root = await getApplicationSupportDirectory();
    }
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}HeartRateLogs',
    );
    await directory.create(recursive: true);
    _file = File(
      '${directory.path}${Platform.pathSeparator}session-$_sessionId.log',
    );
    info(
      'app',
      'logger initialized app=${AppConfig.applicationId} '
          'version=${version.isEmpty ? 'unknown' : version} '
          'session=$_sessionId',
    );
  }

  /// [code] 是便于 grep 的短错误码（如 `gatt_disconnected`、`notify_error`），
  /// 会写进导出日志的 `code=` 字段，方便按断连原因筛选。
  void debug(String module, String message, {String? deviceId, String? code}) =>
      _add(LogLevel.debug, module, message, deviceId, code);
  void info(String module, String message, {String? deviceId, String? code}) =>
      _add(LogLevel.info, module, message, deviceId, code);
  void warn(String module, String message, {String? deviceId, String? code}) =>
      _add(LogLevel.warn, module, message, deviceId, code);
  void error(
    String module,
    String message,
    String? deviceId,
    Object error, [
    StackTrace? stack,
  ]) => _add(LogLevel.error, module, message, deviceId, '$error', stack);

  void _add(
    LogLevel level,
    String module,
    String message,
    String? deviceId, [
    String? code,
    StackTrace? stack,
  ]) {
    if (level == LogLevel.debug && !debugEnabled) return;
    final entry = LogEntry(
      at: DateTime.now().toUtc(),
      level: level,
      module: module,
      message: LogSanitizer.text(message),
      deviceId: deviceId,
      errorCode: code == null ? null : LogSanitizer.text(code),
      stack: stack?.toString(),
    );
    _entries.add(entry);
    if (_entries.length > 1000) _entries.removeAt(0);
    if (!_changes.isClosed) _changes.add(null);
    final file = _file;
    if (file != null) {
      _writeQueue = _writeQueue
          .then((_) async {
            await file.writeAsString(
              '${entry.format()}\n',
              mode: FileMode.append,
              flush: true,
            );
          })
          .catchError((Object error) {
            debugPrint('Log write failed: $error');
          });
    }
  }

  Future<File> export() async {
    await _writeQueue;
    final file = _file;
    if (file != null && await file.exists()) return file;
    final directory = await getTemporaryDirectory();
    final fallback = File(
      '${directory.path}${Platform.pathSeparator}heartrate-$_sessionId.txt',
    );
    await fallback.writeAsString(
      entries.map((entry) => entry.format()).join('\n'),
    );
    return fallback;
  }

  Future<void> share() async {
    final file = await export();
    await SharePlus.instance.share(
      ShareParams(
        title: '分享${Zh.appName}诊断日志',
        files: [
          XFile(
            file.path,
            mimeType: 'text/plain',
            name: 'heartrate-$_sessionId.txt',
          ),
        ],
        text: '${Zh.appName}诊断日志（会话 $_sessionId）',
      ),
    );
  }

  Future<void> dispose() async {
    await _writeQueue;
    await _changes.close();
  }
}
