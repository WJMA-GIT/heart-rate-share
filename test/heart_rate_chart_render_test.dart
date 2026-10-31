import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';

/// 画法层面的检查：缺口**不能**被实线盖住，缺测段只能是"淡色虚线"。
///
/// 这里真的把 widget 画到一张图上再读像素，而不是只断言数据结构 ——
/// 否则"实线跨过缺口"这种回归单测是看不出来的。
void main() {
  testWidgets('缺测段是淡色虚线，实线不跨过缺口', (tester) async {
    final base = DateTime.utc(2026, 10, 31, 12);
    final series = HeartRateSeries();
    // 0–60 秒恒定 64 bpm，其中 21–24 秒没有采样（5 秒短缺测）。
    for (var second = 0; second <= 60; second++) {
      if (second > 20 && second < 25) continue;
      series.add(
        HeartRatePoint(at: base.add(Duration(seconds: second)), bpm: 64),
      );
    }

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 300,
                height: 132,
                child: HeartRateChart(series: series, bpm: 64),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData data;
    late int imageWidth;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      imageWidth = image.width;
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    // 测试环境可能是 3x：所有坐标都按实际像素宽换算。
    final scale = imageWidth / 300.0;
    int px(double logical) => (logical * scale).round();

    /// 折线在 y≈98（64 bpm），绘图区 x∈[26,294]：第 [second] 秒 ≈ 26+second/60*268。
    /// 图是预乘 alpha 的 rgba：实线核心是 (255,255,82,82)，45% 过渡线核心是
    /// (115,115,37,37)，抗锯齿边缘介于两者之间 —— 所以用"缺口内部的最大 alpha"
    /// 判断有没有实线跨过去，比按颜色猜稳。
    int xOf(int second) => px(26 + second / 60 * 268);
    final yFrom = px(96);
    final yTo = px(100);

    int gapMaxAlpha = 0;
    var gapTransparent = 0;
    final gapFrom = xOf(20) + px(3);
    final gapTo = xOf(25) - px(3);
    for (var x = gapFrom; x <= gapTo; x++) {
      for (var y = yFrom; y <= yTo; y++) {
        final alpha = data.getUint8((y * imageWidth + x) * 4 + 3);
        if (alpha > gapMaxAlpha) gapMaxAlpha = alpha;
        if (alpha == 0) gapTransparent++;
      }
    }

    /// 缺口内部：有淡线（alpha > 60），但没有实线（alpha < 200），且虚线有空隙。
    expect(gapMaxAlpha, greaterThan(60), reason: '缺口里要有淡色虚线，否则又变回"断了一截"');
    expect(gapMaxAlpha, lessThan(200), reason: '实线绝不能跨过没有数据的时段');
    expect(gapTransparent, greaterThan(0), reason: '虚线本来就该有空隙');

    // 对照：缺口两侧是真采样，必须有完全不透明的实线核心。
    int solidAround(int second) {
      final center = xOf(second);
      var count = 0;
      for (var x = center - px(2); x <= center + px(2); x++) {
        for (var y = yFrom; y <= yTo; y++) {
          final offset = (y * imageWidth + x) * 4;
          if (data.getUint8(offset + 3) == 255 && data.getUint8(offset) > 200) {
            count++;
          }
        }
      }
      return count;
    }

    expect(solidAround(19), greaterThan(0), reason: '缺口左侧是真实采样');
    expect(solidAround(26), greaterThan(0), reason: '缺口右侧是真实采样');
  });
}
