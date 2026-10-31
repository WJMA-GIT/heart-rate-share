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

    // 名称/心率列现在是**动态测量**（不再有固定常量），这里只比对仍然固定的部分。
    expect(valueOf('GAP_DP'), OverlayMetrics.gap.round());
    expect(valueOf('CHART_WIDTH_DP'), OverlayMetrics.chartWidth.round());
    expect(valueOf('CHART_HEIGHT_DP'), OverlayMetrics.chartHeight.round());
    expect(valueOf('MAX_ROWS_DP'), OverlayMetrics.maxListHeight.round());
    expect(valueOf('NAME_EXTRA_DP'), 2);
    // 动态规则必须在 Kotlin 侧成立：按最长名测量 + 上限 60% 屏宽
    expect(
      source.contains('measureText(name)'),
      isTrue,
      reason: '名称列必须按名字实际宽度测量',
    );
    expect(source.contains('dynamicNameWidth'), isTrue);
    expect(source.contains('dynamicBpmWidth'), isTrue);
    expect(source.contains('* 0.6f'), isTrue, reason: '名称列上限应为屏宽 60%');
  });

  test('名称列宽按最长名字动态测量（同房间共用），两侧 gap 相等', () {
    final source = File(
      'android/app/src/main/kotlin/com/wjmagit/heartrateshare/BleKeepAliveService.kt',
    ).readAsStringSync();
    expect(
      source.contains('width = dynamicNameWidth'),
      isTrue,
      reason: '同一房间共用一个名称列宽（取最长名），心率位置才不跳',
    );
    expect(source.contains('width = dynamicBpmWidth'), isTrue);
    expect(
      source.contains('marginStart = dp(GAP_DP)'),
      isTrue,
      reason: '名称→心率、心率→折线的间距必须相等',
    );
  });
}
