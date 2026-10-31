import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/theme/overlay_metrics.dart';

/// 用假测量器：把每个字符按固定宽度算，方便断言"宽度随名字长度变化"，
/// 不依赖真实字体度量（那台机器上字体可能不同）。
double _fakeMeasure(String text, double fontSize, FontWeight weight) {
  final perChar = fontSize; // 每个字符宽 = 字号（近似全角）
  return text.length * perChar * (weight == FontWeight.bold ? 1.1 : 1.0);
}

OverlayLayout _layout(List<String> names) =>
    computeOverlayLayout(names: names, measure: _fakeMeasure);

void main() {
  test('一个字的名字 → 名称列只有一个字宽，不出现巨大空档', () {
    final one = _layout(['王']);
    final three = _layout(['王小明']);
    expect(one.nameWidth, lessThan(three.nameWidth), reason: '宽度必须跟名字长度走');
    // 一个汉字（12px）+ 2dp 余量
    expect(one.nameWidth, closeTo(12 * 1 + 2, 0.01));
  });

  test('房间内所有行共用最长名字的宽度（短名字不各算各的）', () {
    final layout = _layout(['王', '王小明', '李四']);
    expect(layout.nameWidth, closeTo(3 * 12 + 2, 0.01)); // 最长 3 字
  });

  test('中英混排 / emoji 都参与测量（取最长的那条）', () {
    final mixed = _layout(['Bob', '王小明', '❤️‍🔥']);
    expect(mixed.nameWidth, greaterThan(3 * 12));
  });

  test('名字变长→变短：宽度随之变化（去抖在 UI 层，公式本身无状态）', () {
    final long = _layout(['一个很长的中文名字']);
    final short = _layout(['王']);
    expect(long.nameWidth, greaterThan(short.nameWidth));
    expect(long.totalWidth, greaterThan(short.totalWidth));
  });

  test('两个 gap 相等，心率列按 3 位等宽数字测，总宽公式成立', () {
    final layout = _layout(['王小明']);
    final expected =
        OverlayMetrics.padding * 2 +
        layout.nameWidth +
        OverlayMetrics.gap +
        layout.bpmWidth +
        OverlayMetrics.gap +
        OverlayMetrics.chartWidth;
    expect(layout.totalWidth, closeTo(expected, 0.01));
    // 心率列 ≈ "888" 三字符（粗体 1.1 倍） + 2dp
    expect(layout.bpmWidth, closeTo(3 * 13 * 1.1 + 2, 0.5));
  });

  test('无人时退回一个汉字宽，列宽不塌成 0', () {
    final empty = _layout([]);
    expect(empty.nameWidth, greaterThan(0));
    expect(empty.nameWidth, closeTo(12 + 2, 0.01));
  });

  test('名称列上限生效（超过 60% 屏宽才截断）', () {
    final capped = computeOverlayLayout(
      names: ['很长' * 40],
      maxNameWidth: 200,
      measure: _fakeMeasure,
    );
    expect(capped.nameWidth, 200);
  });
}
