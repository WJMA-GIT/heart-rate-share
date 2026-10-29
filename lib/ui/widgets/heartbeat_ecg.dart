import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 心跳/ECG 视觉：不引入任何动效依赖，纯 CustomPainter + AnimationController。
///
/// 耗电控制：没有心率数据（[bpm] 为空或 [active] 为 false）时**停止**
/// controller，只画一条静止待机基线；有数据时才按 BPM 驱动扫速。
final class HeartbeatEcg extends StatefulWidget {
  const HeartbeatEcg({
    required this.bpm,
    required this.active,
    this.height = 96,
    super.key,
  });

  final int? bpm;
  final bool active;
  final double height;

  @override
  State<HeartbeatEcg> createState() => _HeartbeatEcgState();
}

final class _HeartbeatEcgState extends State<HeartbeatEcg>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _periodFor(widget.bpm),
  );

  static Duration _periodFor(int? bpm) {
    // 60 BPM ≈ 1 秒一个心动周期；限制在 400ms~1.6s，避免极端值把动画抖坏。
    final beats = (bpm ?? 60).clamp(30, 200);
    final ms = (60000 / beats).clamp(400, 1600).round();
    return Duration(milliseconds: ms);
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(HeartbeatEcg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bpm != widget.bpm) {
      _controller.duration = _periodFor(widget.bpm);
    }
    if (oldWidget.active != widget.active) _sync();
  }

  /// 只有"有数据且在接收"时才跑动画，其他情况一律停，杜绝空转耗电。
  void _sync() {
    final shouldRun = widget.active && widget.bpm != null;
    if (shouldRun && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldRun && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _EcgPainter(
            phase: _controller.value,
            active: widget.active && widget.bpm != null,
            color: scheme.error,
            grid: scheme.outlineVariant.withValues(alpha: 0.28),
          ),
        ),
      ),
    );
  }
}

final class _EcgPainter extends CustomPainter {
  _EcgPainter({
    required this.phase,
    required this.active,
    required this.color,
    required this.grid,
  });

  final double phase;
  final bool active;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    final path = Path();
    final samples = math.max(size.width.round(), 64);
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final x = t * size.width;
      final y = size.height * (0.5 - _wave(t) * (active ? 0.34 : 0.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final paint = Paint()
      ..color = active ? color : color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.2 : 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  /// 一个心动周期的波形（P-QRS-T），按 [phase] 横向滚动。
  double _wave(double t) {
    final p = (t + phase * 0.35) % 1.0;
    final qrs = math.exp(-math.pow((p - 0.34) / 0.022, 2)) * 1.0;
    final dip = math.exp(-math.pow((p - 0.40) / 0.018, 2)) * -0.45;
    final pWave = math.exp(-math.pow((p - 0.16) / 0.05, 2)) * 0.18;
    final tWave = math.exp(-math.pow((p - 0.62) / 0.09, 2)) * 0.28;
    return (qrs + dip + pWave + tWave).clamp(-0.6, 1.2);
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    const step = 16.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_EcgPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.active != active;
}
