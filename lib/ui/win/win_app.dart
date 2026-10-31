import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/platform/startup_log.dart';
import '../widgets/heart_rate_chart.dart';
import 'win_controller.dart';
import 'win_drag.dart';

/// Windows 悬浮窗：无边框 + 置顶 + 背景可全透明（原生分层窗口的颜色键实现）。
///
/// 两条通路：**有蓝牙优先 BLE 直连**，否则用局域网投射（扫到手机点一下就连，
/// 不需要房间码）。画法与手机端完全一致：同一个 `normalizedPolyline`。
final class WinApp extends StatefulWidget {
  const WinApp({this.controller, super.key});
  final WinController? controller;

  @override
  State<WinApp> createState() => _WinAppState();
}

final class _WinAppState extends State<WinApp> {
  WinController? _controllerOrNull;
  Object? _fatal;
  bool _owns = false;
  bool _showPanel = true;
  bool _autoConnectTried = false;
  bool _safeMode = false;

  WinController get _controller => _controllerOrNull!;

  @override
  void initState() {
    super.initState();
    // 先建窗口（runApp 已经跑起来了），再在 try/catch 里初始化数据层：
    // 早先 WinController 在 runApp 之前构造，BLE 插件一抛异常就整个进程秒退。
    _safeMode =
        (const String.fromEnvironment('SAFE_MODE') == '1') ||
        (Platform.environment['HEARTRATE_SAFE_MODE'] == '1');
    StartupLog.info('win: init (safeMode=$_safeMode)');
    try {
      final controller = widget.controller ?? WinController();
      _owns = widget.controller == null;
      _controllerOrNull = controller;
      controller.addListener(_onChange);
      StartupLog.info('win: controller ok');
      if (!_safeMode) {
        controller.startDiscovery();
      }
      StartupLog.info('win: discovery requested');
    } catch (error, stack) {
      _fatal = error;
      StartupLog.info('win: FATAL during init: $error');
      StartupLog.info('$stack');
    }
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _maybeAutoConnect();
  }

  /// 记住上次选择的设备：它再次出现就自动连上（用户不需要每次点）。
  void _maybeAutoConnect() {
    if (_autoConnectTried || _controller.connected) return;
    final last = _controller.lastPeerId;
    if (last == null) return;
    final peer = _controller.peers.where((p) => p.id == last).firstOrNull;
    if (peer == null) return;
    _autoConnectTried = true;
    _controller.connectPeer(peer).then((ok) {
      if (ok && mounted) setState(() => _showPanel = false);
    });
  }

  @override
  void dispose() {
    _controllerOrNull?.removeListener(_onChange);
    if (_owns) _controllerOrNull?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 颜色键：与 windows/runner/main.cpp 的 RGB(1,2,3) 对应 → 这些像素 100% 透明。
    if (_fatal != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: ColoredBox(
          color: const Color(0xFF1C1C1E),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '启动异常（窗口还在，说明渲染正常）',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
                const SizedBox(height: 6),
                Text(
                  '$_fatal',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  '日志：${StartupLog.path ?? "未创建"}\n把 startup.log 发回即可定位。',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final transparent = _controller.backgroundTransparent && !_safeMode;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.redAccent,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // Material 祖先：ListTile / IconButton / TextButton 都要 `Material.of(context)`；
      // 直接挂在 ColoredBox 下会在 build 时抛 "Null check operator used on a null value"
      // （1.0.5 的启动日志就是这么被刷了 1.8 MB）。type=transparency 不画底色，
      // 背景仍由外层 ColoredBox + 原生颜色键决定。
      home: Material(
        type: MaterialType.transparency,
        child: ColoredBox(
          color: transparent
              ? const Color(0xFF010203)
              : const Color(0xE61C1C1E),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                if (_showPanel || !_controller.connected) _panel(),
                _rows(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return GestureDetector(
      onPanStart: (_) => startWindowDrag(),
      child: Container(
        color: _controller.backgroundTransparent
            ? const Color(0xFF010203)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.monitor_heart, size: 16, color: Color(0xFFFF5252)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _controller.transportLabel,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: _controller.connected
                      ? Colors.greenAccent
                      : Colors.white70,
                ),
              ),
            ),
            const Spacer(),
            if (_controller.connected)
              TextButton(
                onPressed: _controller.disconnectAll,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('手机投射（同一 Wi-Fi）'),
        _lanList(),
        _manualRow(),
        if (!_safeMode) ...[
          _sectionTitle('蓝牙直连（本机蓝牙）'),
          _bleList(),
        ] else
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Text(
              '安全模式：蓝牙与透明都被跳过（HEARTRATE_SAFE_MODE=1）。'
              '能用说明是这两块的问题，去掉该变量再试。',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        if (_controller.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Text(
              _controller.error!,
              style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11, color: Colors.white54),
    ),
  );

  Widget _lanList() {
    final peers = _controller.peers;
    if (peers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
        child: Text(
          _controller.scanning
              ? '正在扫描同一 Wi-Fi 下的手机…'
              : '没找到手机。检查：①手机与电脑连同一个 Wi-Fi；②手机设置里「投射到局域网」是开的；'
                    '③Windows 防火墙允许本程序的"专用网络"；④路由器没开"AP 隔离"。'
                    '实在不行在下面填手机 IP:端口 手动连。',
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
            title: Text(peer.name, style: const TextStyle(fontSize: 12)),
            subtitle: Text(
              '${peer.platform} · ${peer.members} 人在线',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: TextButton(
              onPressed: () async {
                final ok = await _controller.connectPeer(peer);
                if (ok && mounted) setState(() => _showPanel = false);
              },
              child: const Text('连接'),
            ),
          ),
      ],
    );
  }

  Widget _manualRow() {
    final controller = TextEditingController();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '手动：192.168.1.20:8770',
                hintStyle: TextStyle(fontSize: 11),
              ),
              onSubmitted: (value) async {
                final ok = await _controller.connectManual(value);
                if (ok && mounted) setState(() => _showPanel = false);
              },
            ),
          ),
          TextButton(
            onPressed: () async {
              final ok = await _controller.connectManual(controller.text);
              if (ok && mounted) setState(() => _showPanel = false);
            },
            child: const Text('连', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _bleList() {
    final ble = _controller.ble;
    final devices = ble.devices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
          child: Row(
            children: [
              Text(
                ble.adapterState.isEmpty ? '蓝牙状态未知' : '蓝牙：${ble.adapterState}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const Spacer(),
              TextButton(
                onPressed: _controller.scanBle,
                child: const Text('扫描心率带', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Text(
              '没有蓝牙心率设备：确认系统蓝牙已开、心率带在身上/在附近；'
              '没有蓝牙就用上面的局域网投射。',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
        for (final device in devices)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(
              device.name.isEmpty ? device.id : device.name,
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              'RSSI ${device.rssi}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: TextButton(
              onPressed: () async {
                final ok = await _controller.connectBle(device.id);
                if (ok && mounted) setState(() => _showPanel = false);
              },
              child: const Text('连接'),
            ),
          ),
      ],
    );
  }

  Widget _rows() {
    final rows = <Widget>[];
    if (_controller.transport == WinTransport.ble) {
      rows.add(_row('蓝牙心率带', _controller.ownBpm, _controller.ownSeries, false));
    }
    for (final member in _controller.members) {
      rows.add(
        _row(
          member.report.displayName,
          _controller.liveBpm(member),
          _controller.seriesFor(member.report.memberId),
          !member.online,
        ),
      );
    }
    if (rows.isEmpty) {
      if (!_controller.connected) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.all(10),
        child: Text(
          '等待心率数据…',
          style: TextStyle(fontSize: 11, color: Colors.white70),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _row(String name, int? bpm, HeartRateSeries series, bool offline) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(
              name,
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
            child: CustomPaint(painter: _WinSparkline(series)),
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
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        Paint()
          ..color = const Color(0x59FFFFFF)
          ..strokeWidth = 1,
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
  StartupLog.stage('win: runApp');
  // 无边框/置顶/分层透明全部在 runner（main.cpp）里完成，Dart 侧不再调用任何
  // 窗口管理插件——那个插件子类化 WndProc，正是 0xC000041D 的崩溃来源。
  runApp(const WinApp());
}
