import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';

final _base = DateTime.utc(2026, 10, 31, 12);

HeartRateSeries _series(List<(int seconds, int bpm)> samples) {
  final series = HeartRateSeries();
  for (final (seconds, bpm) in samples) {
    series.add(
      HeartRatePoint(
        at: _base.add(Duration(seconds: seconds)),
        bpm: bpm,
      ),
    );
  }
  return series;
}

void main() {
  test('没有采样就不造点', () {
    expect(normalizedPolyline(HeartRateSeries()).isEmpty, isTrue);
    expect(normalizedPolyline(HeartRateSeries()).bridges, isEmpty);
    expect(overlayPolyline(null).segments, isEmpty);
    expect(overlayPolyline(HeartRateSeries()).segments, isEmpty);
  });

  test('归一化：右端对齐最后采样，30–220 BPM 映射到底..顶', () {
    // 逐秒采样（和 1 Hz 上报一致），整条曲线是一段。
    final samples = [for (var i = 0; i <= 60; i++) (i, 30)];
    samples[60] = (60, 220);
    final segments = normalizedPolyline(_series(samples)).segments;
    expect(segments, hasLength(1));
    expect(segments.first.first.dx, 0);
    expect(segments.first.first.dy, 1, reason: '30 BPM 在最底');
    expect(segments.first.last.dx, 1);
    expect(segments.first.last.dy, 0, reason: '220 BPM 在最顶');
  });

  test('短缺测（3–8 秒）用虚线过渡连起来，不留空白也不冒充数据', () {
    final polyline = normalizedPolyline(_series([(0, 70), (1, 72), (6, 80)]));
    expect(polyline.segments, hasLength(2), reason: '实线不能跨过没有数据的 5 秒');
    expect(polyline.bridges, hasLength(1), reason: '用一段虚线把两边接上');
    final (from, to) = polyline.bridges.single;
    expect(from, polyline.segments.first.last);
    expect(to, polyline.segments.last.first);
    expect(from.dx < to.dx, isTrue, reason: '过渡线按真实时间前进');
  });

  test('长缺测（> 8 秒）才真的断开，且不画过渡线', () {
    final polyline = normalizedPolyline(_series([(0, 70), (1, 72), (20, 80)]));
    expect(polyline.segments, hasLength(2), reason: '19 秒缺测 = 真断流');
    expect(polyline.bridges, isEmpty);
  });

  test('2 秒以内的小抖动既不断开也不画虚线', () {
    final polyline = normalizedPolyline(_series([(0, 70), (2, 72), (3, 74)]));
    expect(polyline.segments, hasLength(1));
    expect(polyline.bridges, isEmpty);
  });

  test('悬浮窗 payload 是扁平 x,y，缺测过渡单独一段', () {
    final series = _series([(56, 60), (57, 90), (60, 120)]);
    final payload = overlayPolyline(series);
    final expected = normalizedPolyline(series).segments
        .expand((s) => s)
        .toList();
    expect(payload.segments, hasLength(1));
    expect(payload.segments.first, hasLength(expected.length * 2));
    for (var index = 0; index < expected.length; index++) {
      expect(payload.segments.first[index * 2], expected[index].dx);
      expect(payload.segments.first[index * 2 + 1], expected[index].dy);
    }
    expect(
      payload.segments.first.every((value) => value >= 0 && value <= 1),
      isTrue,
      reason: '归一化值必须落在 0..1，原生侧直接缩放',
    );
    expect(payload.bridges, isEmpty, reason: '3 秒间隔在过渡阈值内');
  });

  test('恒定心率下曲线随时间左移、右端始终对齐最后一个真实采样', () {
    // 1 Hz 恒定 64：线是平的，但 x 仍按时间推进 —— 不是"冻住的一帧"。
    final series = _series([for (var i = 0; i <= 30; i++) (i, 64)]);
    final first = normalizedPolyline(series).segments.single;
    expect(first.last.dx, 1.0, reason: '右端 = 最后一个真实采样');
    expect(first.first.dx, closeTo(0.5, 1e-9), reason: '60 秒窗口，最早的点在正中');
    expect(
      first.every((point) => point.dy == first.first.dy),
      isTrue,
      reason: '恒定值 → 一条平线',
    );

    // 又来一个采样：整条线左移（早期点被裁），新的最后一点仍在 1.0。
    series.add(
      HeartRatePoint(at: _base.add(const Duration(seconds: 31)), bpm: 64),
    );
    final second = normalizedPolyline(series).segments.single;
    expect(second.last.dx, 1.0);
    expect(second.first.dx, lessThan(0.5), reason: '窗口右移 → 老点向左走');
    expect(second[second.length - 2].dx, closeTo(1 - 1 / 60, 1e-9));
    for (var i = 1; i < second.length; i++) {
      expect(second[i].dx, greaterThan(second[i - 1].dx));
    }
  });

  test('缺测期间曲线不假装延伸：右端停在最后一个真实采样', () {
    final series = _series([for (var i = 0; i <= 10; i++) (i, 64)]);
    // 10 秒没有新采样（时间在走、数据没有）：右端仍是最后一个采样，也不画过渡线。
    final polyline = normalizedPolyline(series);
    expect(polyline.segments.single.last.dx, 1.0);
    expect(polyline.bridges, isEmpty);
  });

  test('首页大图与悬浮窗同色', () {
    expect(HeartRateChartStyle.line.toARGB32(), 0xFFFF5252);
  });
}
