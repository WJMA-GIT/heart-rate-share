import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/logging/app_logger.dart';

final class DebugController extends ChangeNotifier {
  DebugController(this._logger) {
    _subscription = _logger.changes.listen((_) => notifyListeners());
  }
  final AppLogger _logger;
  late final StreamSubscription<void> _subscription;
  bool get enabled => _logger.debugEnabled;
  List<LogEntry> get entries => _logger.entries;

  void setEnabled(bool value) {
    _logger.debugEnabled = value;
    _logger.info('debug', 'Debug panel ${value ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  Future<void> shareLogs() => _logger.share();

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
