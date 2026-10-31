import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';

HeartRatePoint _point(DateTime at, int bpm) => HeartRatePoint(at: at, bpm: bpm);

void main() {
  final base = DateTime.utc(2026, 1, 1, 0, 0, 0);

  test('没有采样就是空的：时间流过不会自己长出数据', () {
    final series = HeartRateSeries();
    expect(series.isEmpty, isTrue);
    expect(series.latest, isNull);
    expect(series.isFreshAt(base), isFalse);
    expect(series.isFreshAt(base.add(const Duration(minutes: 5))), isFalse);
    expect(series.points, isEmpty);
  });

  test('60 秒窗口外的点被丢弃，窗口内保留', () {
    final series = HeartRateSeries();
    series.add(_point(base, 60));
    series.add(_point(base.add(const Duration(seconds: 30)), 70));
    series.add(_point(base.add(const Duration(seconds: 61)), 80));

    expect(series.points.map((p) => p.bpm), [70, 80]);
    expect(series.latest!.bpm, 80);
  });

  test('点数上限 120：更高频率的设备也不会无限增长', () {
    final series = HeartRateSeries();
    for (var i = 0; i < 300; i++) {
      series.add(
        _point(base.add(Duration(milliseconds: 100 * i)), 60 + i % 40),
      );
    }
    expect(series.points.length, lessThanOrEqualTo(120));
    // 保留的是最新的那一段
    expect(series.latest!.at, base.add(const Duration(milliseconds: 29900)));
  });

  test('中断超过 3 秒标为断点，绝不插值补点', () {
    final series = HeartRateSeries();
    series.add(_point(base, 60));
    series.add(_point(base.add(const Duration(seconds: 1)), 62));
    series.add(_point(base.add(const Duration(seconds: 10)), 80));

    expect(series.points, hasLength(3), reason: '不合成中间点');
    expect(series.gapBefore(0), isFalse);
    expect(series.gapBefore(1), isFalse);
    expect(series.gapBefore(2), isTrue);
    expect(series.gapBefore(3), isFalse, reason: '越界不崩');
  });

  test('新鲜度：超过 3 秒没有新采样就没有实时读数', () {
    final series = HeartRateSeries();
    series.add(_point(base, 72));
    expect(series.isFreshAt(base.add(const Duration(seconds: 1))), isTrue);
    expect(series.isFreshAt(base.add(const Duration(seconds: 3))), isTrue);
    expect(series.isFreshAt(base.add(const Duration(seconds: 4))), isFalse);
  });

  test('未来时间戳不算新鲜读数（设备时钟偏差不伪装在线）', () {
    final series = HeartRateSeries();
    series.add(_point(base.add(const Duration(seconds: 30)), 70));
    expect(series.isFreshAt(base), isFalse);
    expect(series.isFreshAt(base.add(const Duration(seconds: 30))), isTrue);
  });

  test('时间往回走的点被丢弃，latest 始终是最新时刻', () {
    final series = HeartRateSeries();
    series.add(_point(base, 60));
    series.add(_point(base.add(const Duration(seconds: 2)), 70));
    series.add(_point(base.add(const Duration(seconds: 1)), 65));
    expect(series.points.map((p) => p.bpm), [60, 70]);
    expect(series.latest!.bpm, 70);
  });

  test('revision 只在写入/清空时变化，避免无谓重绘', () {
    final series = HeartRateSeries();
    expect(series.revision, 0);
    series.add(_point(base, 60));
    final afterAdd = series.revision;
    expect(afterAdd, 1);
    series.clear();
    expect(series.revision, afterAdd + 1);
    series.clear();
    expect(series.revision, afterAdd + 1, reason: '本来就空，不必再通知重绘');
  });
}
