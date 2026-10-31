import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/theme/overlay_metrics.dart';

/// 手机悬浮窗是原生 View，常量没法 import Dart；这条测试在 CI 里逐项比对，
/// 保证「同一套列宽」不是口头承诺（两份不一致直接红）。
void main() {
  test('Kotlin 悬浮窗列宽与 Dart OverlayMetrics 一致', () {
    final file = File(
      'android/app/src/main/kotlin/com/wjmagit/heartrateshare/BleKeepAliveService.kt',
    );
    expect(file.existsSync(), isTrue, reason: '找不到原生悬浮窗实现');
    final source = file.readAsStringSync();

    int valueOf(String name) {
      final match = RegExp('const val $name = (\\d+)').firstMatch(source);
      expect(match, isNotNull, reason: 'Kotlin 里找不到常量 $name');
      return int.parse(match!.group(1)!);
    }

    expect(valueOf('NAME_WIDTH_DP'), OverlayMetrics.nameWidth.round());
    expect(valueOf('BPM_WIDTH_DP'), OverlayMetrics.bpmWidth.round());
    expect(valueOf('CHART_WIDTH_DP'), OverlayMetrics.chartWidth.round());
    expect(valueOf('CHART_HEIGHT_DP'), OverlayMetrics.chartHeight.round());
    expect(valueOf('MAX_ROWS_DP'), OverlayMetrics.maxListHeight.round());
  });

  test('名称列是定宽（不是 maxWidth），心率列定宽右对齐', () {
    final source = File(
      'android/app/src/main/kotlin/com/wjmagit/heartrateshare/BleKeepAliveService.kt',
    ).readAsStringSync();
    expect(
      source.contains('width = dp(NAME_WIDTH_DP)'),
      isTrue,
      reason: '名称列必须定宽，否则名字长短会推走心率数字',
    );
    expect(source.contains('width = dp(BPM_WIDTH_DP)'), isTrue);
  });
}
