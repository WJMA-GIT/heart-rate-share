import 'package:flutter/material.dart';

import '../../ble/heart_rate_sample.dart';
import '../../core/l10n/strings_zh.dart';

/// 一个真实采样点：什么时候收到的、当时的 BPM。
final class HeartRatePoint {
  const HeartRatePoint({required this.at, required this.bpm});

  final DateTime at;
  final int bpm;
}

/// 最近一段时间里的真实采样序列。
///
/// 只做三件事：按时间窗裁剪、按点数上限裁剪、标出"数据中断"的断点。
/// **不插值、不补点、不沿用最后一个值**：没有新采样时曲线就停在最后一个真实
/// 采样上，界面据此显示待机，而不是画一条假装还在跳的线。
final class HeartRateSeries {
  HeartRateSeries({
    this.window = const Duration(seconds: 60),
    this.maxPoints = 120,
    this.gapAfter = const Duration(seconds: 3),
    this.bridgeAfter = const Duration(seconds: 8),
  });

  /// 横轴窗口：默认 60 秒。
  final Duration window;

  /// 纵轴取值区间（BPM）。超出区间只影响画法，不改数据。
  static const minBpm = 30;
  static const maxBpm = 220;

  /// 点数上限：1 Hz 下 60 秒只有 60 点，留一倍余量给更快的设备。
  final int maxPoints;

  /// 相邻采样间隔超过它就算"缺测"：不再当作连续曲线。
  final Duration gapAfter;

  /// 短缺测的上限：≤ 它用淡色虚线过渡（看得出是缺测），> 它才真的断开。
  ///
  /// 一次 1006 掉线通常造成 4~6 秒空洞（链路先静默几秒才被对端关掉），旧规则
  /// 3 秒就断，用户看到的是曲线上"中间断了一截"。8 秒能盖住常见重连窗口，
  /// 又不会把真正的长时间离线糊成一条线。
  final Duration bridgeAfter;

  final List<HeartRatePoint> _points = [];
  int _revision = 0;

  List<HeartRatePoint> get points => List.unmodifiable(_points);

  /// 每次写入 +1，供 [CustomPainter] 判断是否需要重绘。
  int get revision => _revision;

  bool get isEmpty => _points.isEmpty;

  HeartRatePoint? get latest => _points.isEmpty ? null : _points.last;

  void addSample(HeartRateSample sample) =>
      add(HeartRatePoint(at: sample.receivedAt, bpm: sample.bpm));

  void add(HeartRatePoint point) {
    final last = latest;
    // 时间往回走的点直接丢弃：曲线只能按真实时间前进，不能倒着画。
    if (last != null && point.at.isBefore(last.at)) return;
    _points.add(point);
    _trim(point.at);
    _revision++;
  }

  void clear() {
    if (_points.isEmpty) return;
    _points.clear();
    _revision++;
  }

  // 以最新采样时刻为基准裁剪：设备时间戳整体偏移时窗口仍然成立。
  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    _points.removeWhere((point) => point.at.isBefore(cutoff));
    if (_points.length > maxPoints) {
      _points.removeRange(0, _points.length - maxPoints);
    }
  }

  /// 现在还算"有实时读数"吗？超过 [gapAfter] 没有新采样就是断了。
  bool isFreshAt(DateTime now) {
    final last = latest;
    if (last == null) return false;
    final delta = now.difference(last.at);
    // 负差值 = 采样时间在未来（设备时钟偏差/脏数据），不能当成"新鲜"。
    return !delta.isNegative && delta <= gapAfter;
  }

  /// 第 [index] 个点之前是否中断（折线要在那里断开）。
  bool gapBefore(int index) {
    if (index <= 0 || index >= _points.length) return false;
    return _points[index].at.difference(_points[index - 1].at) > gapAfter;
  }
}

/// 折线配色：首页大图与悬浮窗小图共用同一份。
///
/// 悬浮窗画在原生窗口里（不是 Flutter 画布），取值由
/// `BleKeepAliveService.kt` 里的 `CHART_LINE_COLOR` 对齐到同一个 ARGB。
abstract final class HeartRateChartStyle {
  static const line = Color(0xFFFF5252);
}

/// 一条可画的心率折线：实线段 + 缺测过渡。
///
/// [segments] 是真实采样连成的实线，遇到 > [HeartRateSeries.gapAfter] 的缺测就断开
/// （实线绝不跨越没有数据的时段）；[bridges] 是 ≤ [HeartRateSeries.bridgeAfter] 的
/// 短缺测过渡线，画成淡色虚线：曲线看起来连续，但仍能看出"这段没有采样"。
final class HeartRatePolyline {
  const HeartRatePolyline({required this.segments, required this.bridges});

  final List<List<Offset>> segments;
  final List<(Offset, Offset)> bridges;

  bool get isEmpty => segments.isEmpty;
}

/// 把序列映射成**归一化折线**：x/y 都在 0..1（y = 0 在顶部）。
///
/// 这是首页 132dp 大图与悬浮窗小图**唯一**的一份画法：两端只负责把归一化点
/// 缩放到各自的矩形里，不各自算一遍窗口/量程，避免两处画出两条不同的线。
HeartRatePolyline normalizedPolyline(HeartRateSeries series) {
  final points = series.points;
  if (points.isEmpty) {
    return const HeartRatePolyline(segments: [], bridges: []);
  }
  // 右端对齐最后一个真实采样：不把"现在"当成数据点，断流后曲线不自己延长。
  final windowStart = points.last.at.subtract(series.window);
  final span = series.window.inMilliseconds.toDouble();
  const spanBpm = HeartRateSeries.maxBpm - HeartRateSeries.minBpm;
  final segments = <List<Offset>>[];
  final bridges = <(Offset, Offset)>[];
  var current = <Offset>[];
  for (var index = 0; index < points.length; index++) {
    final point = points[index];
    final ratio = point.at.difference(windowStart).inMilliseconds / span;
    final offset = Offset(
      ratio.clamp(0.0, 1.0).toDouble(),
      1 - ((point.bpm - HeartRateSeries.minBpm) / spanBpm).clamp(0.0, 1.0),
    );
    if (index > 0 && series.gapBefore(index)) {
      final gap = point.at.difference(points[index - 1].at);
      if (gap <= series.bridgeAfter) bridges.add((current.last, offset));
      segments.add(current);
      current = <Offset>[];
    }
    current.add(offset);
  }
  segments.add(current);
  return HeartRatePolyline(segments: segments, bridges: bridges);
}

/// 悬浮窗用：把折线压成通道能直接传的扁平坐标（x/y 交错）+ 缺测过渡线。
({List<List<double>> segments, List<List<double>> bridges}) overlayPolyline(
  HeartRateSeries? series,
) {
  if (series == null) return (segments: const [], bridges: const []);
  final polyline = normalizedPolyline(series);
  return (
    segments: [
      for (final segment in polyline.segments)
        [
          for (final point in segment) ...[point.dx, point.dy],
        ],
    ],
    bridges: [
      for (final (from, to) in polyline.bridges)
        [from.dx, from.dy, to.dx, to.dy],
    ],
  );
}

/// 实时心率滚动折线：横轴时间（默认 60 秒）、纵轴 BPM，数据全部来自真实采样。
///
/// 没有采样时只留一条静止基线加"暂无数据"，绝不生成假点；数据中断时折线停在
/// 最后一个真实采样，不延伸到当前时刻。
final class HeartRateChart extends StatelessWidget {
  const HeartRateChart({
    required this.series,
    this.bpm,
    this.height = 132,
    super.key,
  });

  final HeartRateSeries series;

  /// 当前实时 BPM（调用方已按新鲜度判定；null = 现在没有在跳的读数）。
  final int? bpm;

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final standby = series.isEmpty;
    return Semantics(
      container: true,
      label: standby
          ? '心率趋势图，最近 ${series.window.inSeconds} 秒，暂无数据'
          : '心率趋势图，最近 ${series.window.inSeconds} 秒，'
                '${series.points.length} 个采样点，当前 ${bpm ?? '无'} BPM',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ChartPainter(
                  series: series,
                  revision: series.revision,
                  line: HeartRateChartStyle.line,
                  grid: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.35,
                  ),
                  label: theme.colorScheme.onSurfaceVariant,
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                ),
              ),
            ),
            if (standby)
              Center(
                child: Text(Zh.noChartData, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.revision,
    required this.line,
    required this.grid,
    required this.label,
    required this.textDirection,
    required this.textScaler,
  });

  final HeartRateSeries series;
  final int revision;
  final Color line;
  final Color grid;
  final Color label;
  final TextDirection textDirection;
  final TextScaler textScaler;

  static const _axisWidth = 26.0;
  static const _axisHeight = 14.0;
  static const _padTop = 8.0;
  static const _padRight = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _axisWidth,
      _padTop,
      size.width - _padRight,
      size.height - _axisHeight,
    );
    if (plot.width <= 1 || plot.height <= 1) return;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final bpm in const [60, 120, 180]) {
      final y = _y(bpm, plot);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(canvas, '$bpm', Offset(plot.left - 4, y), alignRight: true);
    }
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      gridPaint,
    );
    _text(
      canvas,
      '-${series.window.inSeconds}s',
      Offset(plot.left, plot.bottom + _axisHeight / 2),
    );
    _text(
      canvas,
      Zh.chartLatestLabel,
      Offset(plot.right, plot.bottom + _axisHeight / 2),
      alignRight: true,
    );

    final polyline = normalizedPolyline(series);
    if (polyline.isEmpty) return;

    Offset map(Offset normalized) => Offset(
      plot.left + normalized.dx * plot.width,
      plot.top + normalized.dy * plot.height,
    );

    final solid = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (final segment in polyline.segments) {
      path.moveTo(map(segment.first).dx, map(segment.first).dy);
      for (final point in segment.skip(1)) {
        final offset = map(point);
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, solid);
    // 短缺测（≤ bridgeAfter）：淡色虚线连过去，能看出这段没有采样。
    final bridgePaint = Paint()
      ..color = line.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in polyline.bridges) {
      _dashed(canvas, map(from), map(to), bridgePaint);
    }
    canvas.drawCircle(
      map(polyline.segments.last.last),
      3,
      Paint()..color = line,
    );
  }

  /// 虚线：缺测过渡专用，避免把"没有数据"画成和真实采样一样的实线。
  void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 5.0;
    const gap = 4.0;
    final delta = to - from;
    final length = delta.distance;
    if (length <= 0) return;
    final step = delta / length;
    for (var pos = 0.0; pos < length; pos += dash + gap) {
      final end = (pos + dash).clamp(0.0, length);
      canvas.drawLine(from + step * pos, from + step * end, paint);
    }
  }

  double _y(int bpm, Rect plot) {
    final ratio =
        (bpm - HeartRateSeries.minBpm) /
        (HeartRateSeries.maxBpm - HeartRateSeries.minBpm);
    return plot.bottom - ratio.clamp(0.0, 1.0).toDouble() * plot.height;
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: 9, color: label),
      ),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final dx = alignRight ? at.dx - painter.width : at.dx;
    painter.paint(canvas, Offset(dx, at.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.revision != revision ||
      old.line != line ||
      old.grid != grid ||
      old.label != label ||
      old.textScaler != textScaler;
}
