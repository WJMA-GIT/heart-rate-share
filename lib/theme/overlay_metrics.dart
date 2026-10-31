import 'package:flutter/material.dart';

/// 悬浮窗（手机原生 + Windows 紧凑态）的**唯一**尺寸来源。
///
/// 名称列不再固定 96dp：按「房间内最长名字」的实际渲染宽度动态算，
/// 同一房间所有行共用这一个宽度（所以心率数字不会被短名字挤动）。
abstract final class OverlayMetrics {
  /// 名称 → 心率、心率 → 折线的间距：两处**相等**。
  static const gap = 8.0;

  /// 迷你折线列固定宽/高（画法不变）。
  static const chartWidth = 72.0;
  static const chartHeight = 20.0;

  /// 单行高度（紧凑态）：行高 = 这个值 × 缩放。
  static const rowHeight = 22.0;

  /// 多人时窗口最大高度，超出内部滚动。
  static const maxListHeight = 220.0;

  /// 卡片内边距（左右各一份）。
  static const padding = 8.0;

  /// 名称列上限：超过屏宽 60% 才省略（阈值集中在这里）。
  static const nameMaxScreenRatio = 0.6;

  /// 保留给 Windows 紧凑态/旧调用方的兜底默认值（真实布局请用 [computeOverlayLayout]）。
  static const nameWidth = 96.0;
  static const bpmWidth = 48.0;
}

/// 悬浮窗布局：**纯函数**（除文字测量外无副作用），Dart 侧单测直接覆盖。
///
/// 公式：
/// `总宽 = 内边距 + 名称列(最长名宽+2) + gap + 心率列 + gap + 折线列 + 内边距`
///
/// - 名称列 = 最长名字的渲染宽度 + 2dp 安全余量（不额外留白）；
/// - 心率列 = `888` 的宽度（等宽数字，2→3 位不跳），最少 3 位宽；
/// - 两侧 gap 相等（[OverlayMetrics.gap]）。
final class OverlayLayout {
  const OverlayLayout({
    required this.nameWidth,
    required this.bpmWidth,
    required this.gap,
    required this.chartWidth,
    required this.padding,
  });

  final double nameWidth;
  final double bpmWidth;
  final double gap;
  final double chartWidth;
  final double padding;

  /// 一行内容宽（不含左右内边距）。
  double get contentWidth => nameWidth + gap + bpmWidth + gap + chartWidth;

  /// 窗口宽（含左右内边距）。
  double get totalWidth => contentWidth + padding * 2;

  @override
  String toString() =>
      'OverlayLayout(name=${nameWidth.toStringAsFixed(1)}, bpm=${bpmWidth.toStringAsFixed(1)}, total=${totalWidth.toStringAsFixed(1)})';
}

/// 测量文本宽度（可注入，便于单测与 Kotlin 侧对齐）。
typedef MeasureText = double Function(
  String text,
  double fontSize,
  FontWeight weight,
);

/// 默认测量：与显示端同一套字号/字重（用 TextPainter，含 emoji/中文/宽字符）。
double measureTextWidth(
  String text,
  double fontSize,
  FontWeight weight, {
  double textScale = 1.0,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, fontWeight: weight),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScale),
  )..layout();
  return painter.width;
}

/// 计算悬浮窗布局。
///
/// - [names]：房间内成员名字（只取在线成员）；
/// - [nameFontSize]：名称字号（原生侧 12sp）；
/// - [bpmFontSize]：心率字号（原生侧 13sp 粗体）；
/// - [maxNameWidth]：名称列上限（默认屏宽 60%），超出才省略；
/// - [measure]：测量实现，默认 [measureTextWidth]。
OverlayLayout computeOverlayLayout({
  required List<String> names,
  double nameFontSize = 12,
  double bpmFontSize = 13,
  double? maxNameWidth,
  MeasureText? measure,
}) {
  final measureFn = measure ?? measureTextWidth;
  var nameWidth = 0.0;
  for (final name in names) {
    final width = measureFn(name, nameFontSize, FontWeight.normal);
    if (width > nameWidth) nameWidth = width;
  }
  // 最短也要能放下一个中文字，避免"没人/名字为空"时列宽塌成 0。
  if (nameWidth < measureFn('宽', nameFontSize, FontWeight.normal)) {
    nameWidth = measureFn('宽', nameFontSize, FontWeight.normal);
  }
  nameWidth += 2; // 安全余量，只够防裁剪
  if (maxNameWidth != null && nameWidth > maxNameWidth) {
    nameWidth = maxNameWidth;
  }

  // 心率列按 3 位等宽数字测（999 比 888 宽一点点，用 8 更稳妥）。
  final bpmWidth = measureFn('888', bpmFontSize, FontWeight.bold) + 2;

  return OverlayLayout(
    nameWidth: nameWidth,
    bpmWidth: bpmWidth,
    gap: OverlayMetrics.gap,
    chartWidth: OverlayMetrics.chartWidth,
    padding: OverlayMetrics.padding,
  );
}
