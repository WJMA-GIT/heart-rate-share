import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观模式：跟随系统 / 浅色 / 深色，持久化键 `ui.themeMode`。
final class ThemeController extends ChangeNotifier {
  static const key = 'ui.themeMode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(key);
      _mode = switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      _mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      });
    } catch (_) {}
  }
}

/// 全局单例（页面直接读，避免层层传参）。
final themeController = ThemeController();
