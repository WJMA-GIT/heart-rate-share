import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/theme/app_theme.dart';
import 'package:heartrate/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('浅色/深色共用同一套令牌：主色 #FF5252，深色底 #121212 / 卡 #1C1C1E', () {
    final light = AppTheme.mobile();
    final dark = mobileDarkTheme();
    expect(light.colorScheme.primary, AppColors.brand);
    expect(dark.colorScheme.primary, AppColors.brand);
    expect(dark.scaffoldBackgroundColor, const Color(0xFF121212));
    expect(dark.colorScheme.surface, const Color(0xFF1C1C1E));
    expect(AppColorsDark.text, const Color(0xFFE0E0E0));
    expect(AppColorsDark.textDim, const Color(0xFF9A9A9A));
    // 圆角/间距/字号令牌两端一致（同一份常量）
    expect(AppRadius.card, 12);
    expect(AppTextSize.hero, 28);
  });

  test('默认跟随系统；选择可持久化并读回', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = ThemeController();
    await controller.load();
    expect(controller.mode, ThemeMode.system, reason: '默认必须跟随系统');

    await controller.setMode(ThemeMode.dark);
    expect(controller.mode, ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.key), 'dark');

    final reloaded = ThemeController();
    SharedPreferences.setMockInitialValues({'ui.themeMode': 'light'});
    await reloaded.load();
    expect(reloaded.mode, ThemeMode.light);
  });
}
