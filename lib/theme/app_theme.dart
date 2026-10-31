import 'package:flutter/material.dart';

/// 全平台共用的一份视觉常量与主题。
///
/// 取值**来自手机端现状**（Android 首页折线 / 悬浮窗行 / 卡片），Windows 端不得再自定义
/// 另一套色值：`lib/ui/win/win_app.dart` 里的 `WinColors` 只是这里的别名。
abstract final class AppColors {
  /// 手机端折线、BPM 数值、悬浮窗强调色（`HeartRateChartStyle.line` 同一个值）。
  static const brand = Color(0xFFFF5252);

  /// 页面底色（手机深色主题的 scaffold 底）。
  static const bg = Color(0xFF121214);

  /// 卡片 / 悬浮窗胶囊底（手机悬浮窗原来用的是 #1C1C1E，这里同一档）。
  static const surface = Color(0xFF1C1C1E);

  /// 卡片内的抬升面（选中项、头像底、输入框底）。
  static const surfaceHigh = Color(0xFF242428);

  /// 1px 描边 / 分隔线。
  static const line = Color(0xFF2C2C33);

  /// 正文（手机端悬浮窗正文为纯白，桌面沿用同档亮度）。
  static const text = Color(0xFFFFFFFF);

  /// 次要文字 / 离线态（手机端离线灰 #B0B0B0）。
  static const textDim = Color(0xFFB0B0B0);

  /// 在线状态。
  static const ok = Color(0xFF4ADE80);

  /// 警示（连接中/错误提示）。**不用于正文文字**：规范禁止黄色文字。
  static const warn = Color(0xFFFBBF24);
}

/// 圆角与间距：与手机端一致（卡片 12、悬浮窗胶囊 14、按钮/导航项 8、栅格 8）。
abstract final class AppRadius {
  static const button = 8.0;
  static const card = 12.0;
  static const capsule = 14.0;
}

abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
}

/// 字号阶梯：手机端 12/14/16/20/28（BPM 大字 28）。
abstract final class AppTextSize {
  static const caption = 12.0;
  static const body = 14.0;
  static const section = 16.0;
  static const title = 20.0;
  static const hero = 28.0;
}

abstract final class AppTheme {
  /// 手机端主题（main.dart 用它，保持现状不变）。
  static ThemeData mobile() =>
      ThemeData(colorSchemeSeed: AppColors.brand, useMaterial3: true);

  /// 桌面端主题：**同一套色值**，只是补上桌面需要的组件外观（按钮/卡片/输入框）。
  static ThemeData desktop() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.brand,
          brightness: Brightness.dark,
        ).copyWith(
          primary: AppColors.brand,
          onPrimary: Colors.white,
          surface: AppColors.surface,
          onSurface: AppColors.text,
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.button),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      // 显式字体链：中文优先微软雅黑，再退 Segoe UI，最后 sans-serif。
      // 不写死这个的话，缺中文字体的环境（离屏渲染/精简系统）会渲染成方块或乱码。
      fontFamily: 'Microsoft YaHei UI',
      fontFamilyFallback: const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', 'sans-serif'],
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: Colors.white,
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          textStyle: const TextStyle(
            fontSize: AppTextSize.body,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.text,
          side: const BorderSide(color: AppColors.line),
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      // 次要动作用链接样式，但明确去掉下划线、不用黄色。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textDim,
          textStyle: const TextStyle(
            fontSize: AppTextSize.caption,
            decoration: TextDecoration.none,
          ),
          shape: shape,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        hintStyle: const TextStyle(
          fontSize: AppTextSize.caption,
          color: AppColors.textDim,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(color: AppColors.brand, width: 1.5),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: AppColors.textDim),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.brand
              : AppColors.surfaceHigh,
        ),
      ),
    );
  }
}
