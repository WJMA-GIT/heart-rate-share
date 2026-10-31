import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/l10n/strings_zh.dart';
import '../../room/protocol.dart';
import '../widgets/heart_rate_chart.dart';
import 'win_controller.dart';

/// Windows 悬浮窗：无边框 + 置顶 + 背景可全透明（原生分层窗口的颜色键实现）。
///
/// 画法与手机端完全一致：同一个 `normalizedPolyline`（缺测 ≤8 s 画淡色虚线、
/// > 8 s 断开），同一个配色 `#FF5252`。
final class WinApp extends StatefulWidget {
  const WinApp({this.controller, super.key});

  final WinController? controller;

  @override
  State<WinApp> createState() => _WinAppState();
}

final class _WinAppState extends State<WinApp> {
  late final WinController _controller = widget.controller ?? WinController();
  late final bool _owns = widget.controller == null;
  bool _showPanel = true;

  @override
  void initState() {
    super.initState();
    _controller.startDiscovery();
    _controller.addListener(_onChange);
    _applyWindow();
  }

  void _onChange() => setState(() {});

  Future<void> _applyWindow() async {
    try {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setMinimumSize(const Size(220, 90));
    } catch (_) {
      // 非 Windows 或插件不可用时忽略（测试环境）
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    if (_owns) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 颜色键：与 windows/runner/main.cpp 里的 RGB(1,2,3) 对应 → 这些像素 100% 透明。
    final transparent = _controller.backgroundTransparent;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.redAccent,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ColoredBox(
        color: transparent ? const Color(0xFF010203) : const Color(0xE61C1C1E),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            if (!_controller.connected || _showPanel) _panel(),
            _rows(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final room = _controller.connectedRoom ?? '----';
    return GestureDetector(
      // 按住标题条拖动整个窗口（无边框窗口需要自己处理拖动）。
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        color: _controller.backgroundTransparent
            ? const Color(0xFF010203)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.monitor_heart, size: 16, color: Color(0xFFFF5252)),
            const SizedBox(width: 6),
            Text(
              '房间 $room',
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(
              _controller.transportLabel,
              style: TextStyle(
                fontSize: 11,
                color: _controller.connected ? Colors.greenAccent : Colors.grey,
              ),
            ),
            const Spacer(),
            if (_controller.connected)
              TextButton(
                onPressed: _controller.disconnect,
                child: const Text('断开', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              tooltip: '背景透明/深色',
              iconSize: 16,
              onPressed: _controller.toggleBackground,
              icon: Icon(
                _controller.backgroundTransparent
                    ? Icons.opacity
                    : Icons.brightness_2_outlined,
                color: Colors.white70,
              ),
            ),
            IconButton(
              tooltip: '连接设置',
              iconSize: 16,
              onPressed: () => setState(() => _showPanel = !_showPanel),
              icon: const Icon(Icons.settings_ethernet, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel() {
    final peers = _controller.peers;
    if (peers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          _controller.scanning
              ? '正在扫描同一 Wi-Fi 下的手机…'
              : '没发现手机：确认手机开了「投射到局域网」且在同一 Wi-Fi',
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      );
    }
    return Column(
      children: [
        for (final peer in peers)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(
              '${peer.name} · ${peer.host}',
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              '房间 ${peer.room}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: TextButton(
              onPressed: () async {
                final ok = await _controller.connect(peer);
                if (ok && mounted) setState(() => _showPanel = false);
              },
              child: const Text('连接'),
            ),
          ),
      ],
    );
  }

  Widget _rows() {
    final members = _controller.members;
    if (!_controller.connected) {
      if (_controller.error != null) {
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            _controller.error!,
            style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    if (members.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: Text(
          '等待成员加入…',
          style: TextStyle(fontSize: 11, color: Colors.white70),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final member in members) _row(member)],
    );
  }

  Widget _row(MemberState member) {
    final offline = !member.online;
    final bpm = _controller.liveBpm(member);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(
              member.report.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: offline ? const Color(0xFFB0B0B0) : Colors.white,
                shadows: const [
                  Shadow(blurRadius: 3, color: Color(0xCC000000)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 38,
            child: Text(
              offline ? '离线' : (bpm == null ? '--' : '$bpm'),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: offline
                    ? const Color(0xFF9E9E9E)
                    : const Color(0xFFFF5252),
                shadows: const [
                  Shadow(blurRadius: 3, color: Color(0xCC000000)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            height: 20,
            child: CustomPaint(
              painter: _WinSparkline(
                _controller.seriesFor(member.report.memberId),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 迷你折线：与首页/手机悬浮窗同一份 `normalizedPolyline`（缺测虚线规则一致）。
final class _WinSparkline extends CustomPainter {
  _WinSparkline(this.series);
  final HeartRateSeries series;

  @override
  void paint(Canvas canvas, Size size) {
    final polyline = normalizedPolyline(series);
    if (polyline.isEmpty) {
      final paint = Paint()
        ..color = const Color(0x59FFFFFF)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }
    Offset map(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final solid = Paint()
      ..color = const Color(0xFFFF5252)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
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

    final bridgePaint = Paint()
      ..color = const Color(0x73FF5252)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (from, to) in polyline.bridges) {
      final a = map(from);
      final b = map(to);
      final delta = b - a;
      final length = delta.distance;
      if (length <= 0) continue;
      final step = delta / length;
      for (var pos = 0.0; pos < length; pos += 5) {
        final end = (pos + 3).clamp(0.0, length);
        canvas.drawLine(a + step * pos, a + step * end, bridgePaint);
      }
    }
    canvas.drawCircle(
      map(polyline.segments.last.last),
      2,
      Paint()..color = const Color(0xFFFF5252),
    );
  }

  @override
  bool shouldRepaint(_WinSparkline old) =>
      old.series.revision != series.revision;
}

/// Windows 入口。
Future<void> runWinApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await windowManager.ensureInitialized();
  } catch (_) {}
  runApp(const WinApp());
}

/// 供设置页/日志复用的小文案（与手机端保持一致的措辞）。
String winTransportHint() => Zh.lanTitle;
