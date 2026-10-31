import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';

HeartRateSeries _series(List<int> bpms) {
  final s = HeartRateSeries();
  final base = DateTime.utc(2026, 11, 1, 12);
  for (var i = 0; i < bpms.length; i++) {
    s.add(
      HeartRatePoint(
        at: base.add(Duration(seconds: i)),
        bpm: bpms[i],
      ),
    );
  }
  return s;
}

double _yRange(List<int> bpms) {
  final polyline = normalizedPolyline(_series(bpms));
  final ys = [for (final seg in polyline.segments) ...seg.map((o) => o.dy)];
  return ys.reduce((a, b) => a > b ? a : b) -
      ys.reduce((a, b) => a < b ? a : b);
}

void main() {
  group('纵轴刻度跟随动态量程', () {
    List<int> ticksFor(List<int> bpms) {
      final series = _series(bpms);
      normalizedPolyline(series); // 让 rangeState 生效
      return heartRateTicks(series.range);
    }

    test('64±3：刻度覆盖窗内 min/max、整数、等差', () {
      final series = _series([61, 67, 61, 67]);
      final polyline = normalizedPolyline(series);
      final ticks = heartRateTicks(series.range);
      expect(ticks.length, inInclusiveRange(2, 6));
      expect(ticks.first, lessThanOrEqualTo(61));
      expect(ticks.last, greaterThanOrEqualTo(67));
      final step = ticks[1] - ticks[0];
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i] - ticks[i - 1], step, reason: '刻度必须等差');
        expect(ticks[i], isA<int>());
      }
      // 曲线不越出绘图区（y ∈ 0..1）
      final ys = [for (final seg in polyline.segments) ...seg.map((o) => o.dy)];
      expect(ys.every((y) => y >= 0 && y <= 1), isTrue);
      expect(ticks, isNotEmpty);
    });

    test('60→140：刻度覆盖到 140，且与 64±3 的刻度不同（确实在变）', () {
      final narrow = ticksFor([61, 67, 61, 67]);
      final wide = ticksFor([60, 60, 140, 140]);
      expect(wide.first, lessThanOrEqualTo(60));
      expect(wide.last, greaterThanOrEqualTo(140));
      final step = wide[1] - wide[0];
      for (var i = 1; i < wide.length; i++) {
        expect(wide[i] - wide[i - 1], step);
      }
      expect(wide, isNot(equals(narrow)), reason: '量程变了刻度必须跟着变');
    });

    test('恒定 64：刻度围绕 64 且量程 ≥10', () {
      final series = _series(List.filled(10, 64));
      normalizedPolyline(series);
      final ticks = heartRateTicks(series.range);
      expect(ticks.first, lessThanOrEqualTo(64));
      expect(ticks.last, greaterThanOrEqualTo(64));
      expect(series.range.span, greaterThanOrEqualTo(HeartRateRange.minSpan));
    });
  });

  test('恒定 64：量程至少 10 bpm，曲线居中平直', () {
    final series = _series(List.filled(20, 64));
    final polyline = normalizedPolyline(series);
    final ys = [for (final seg in polyline.segments) ...seg.map((o) => o.dy)];
    expect(ys.toSet().length, 1, reason: '恒定值应是一条水平线');
    expect(ys.first, closeTo(0.5, 0.02), reason: '应居中');
    expect(series.range.span, greaterThanOrEqualTo(HeartRateRange.minSpan));
  });

  test('64±3：起伏必须可见（占纵轴 ≥20%）', () {
    final ys = _yRange([61, 67, 61, 67, 61, 67, 61, 67]);
    expect(ys, greaterThan(0.2), reason: '10 bpm 以内的小波动也要看得出来');
  });

  test('60→140 跳变：不裁切（y 在 0..1 且占满大部分高度）', () {
    final series = _series([60, 60, 140, 140]);
    final polyline = normalizedPolyline(series);
    final ys = [for (final seg in polyline.segments) ...seg.map((o) => o.dy)];
    expect(ys.every((y) => y >= 0 && y <= 1), isTrue);
    expect(
      ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b),
      greaterThan(0.7),
    );
    expect(series.range.low, lessThanOrEqualTo(60));
    expect(series.range.high, greaterThanOrEqualTo(140));
  });

  test('缓慢漂移：迟滞生效，量程不反复缩放', () {
    final series = HeartRateSeries();
    final base = DateTime.utc(2026, 11, 1, 12);
    var bpm = 70;
    final spans = <double>[];
    for (var i = 0; i < 40; i++) {
      bpm += (i.isEven ? 1 : 0); // 每 2 秒 +1 bpm，缓慢上漂
      series.add(
        HeartRatePoint(
          at: base.add(Duration(seconds: i)),
          bpm: bpm,
        ),
      );
      normalizedPolyline(series);
      spans.add(series.range.span);
    }
    // 迟滞 + 10 bpm 台阶：量程变化次数必须远少于帧数（每帧都变就是没迟滞）。
    // 实测 40 帧里约 12 次（持续上漂会不断跨台阶），远低于"每帧都变"的 39 次。
    final changes = <double>[];
    for (var i = 1; i < spans.length; i++) {
      if ((spans[i] - spans[i - 1]).abs() > 0.01) changes.add(spans[i]);
    }
    expect(
      changes.length,
      lessThan(spans.length ~/ 2),
      reason: '量程变化次数应为帧数的一半以下（迟滞生效）',
    );
  });
}
