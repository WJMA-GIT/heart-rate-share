import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/theme/app_theme.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';
import 'package:heartrate/ui/win/win_app.dart';

/// 桌面界面截图（不是 golden 对比，是真的把 widget 画成 PNG）：
/// 桌面没有可截的显示会话，所以用离屏渲染出图，产物放 build/win-screenshots/。
MemberState _member(String id, String name, int bpm, {bool online = true}) =>
    MemberState(
      report: HeartRateReport(
        memberId: id,
        displayName: name,
        bpm: bpm,
        rrIntervalsMs: const [830],
        sensorContact: true,
        sequence: 1,
        measuredAt: DateTime.utc(2026, 10, 31, 12),
      ),
      lastSeen: DateTime.utc(2026, 10, 31, 12),
      online: online,
    );

HeartRateSeries _series() {
  final s = HeartRateSeries();
  final base = DateTime.utc(2026, 10, 31, 12);
  for (var i = 0; i <= 40; i++) {
    final bpm = 68 + (i % 7) - 3;
    s.add(
      HeartRatePoint(
        at: base.add(Duration(seconds: i)),
        bpm: bpm,
      ),
    );
  }
  return s;
}

Future<void> _shoot(WidgetTester tester, Widget child, String name) async {
  // 默认测试画布只有 800x600，会把桌面布局裁掉一半 —— 显式设成 1100x680。
  await tester.binding.setSurfaceSize(const Size(1100, 680));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: WinTheme.data(),
      home: RepaintBoundary(
        key: key,
        child: SizedBox(width: 1100, height: 680, child: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late ByteData bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  });
  final dir = Directory('build/win-screenshots');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  testWidgets('连接页截图', (tester) async {
    await _shoot(
      tester,
      Scaffold(
        backgroundColor: WinColors.bg,
        body: ConnectView(
          adapterState: 'on',
          bleBusy: 'idle',
          devices: const [
            _FakeDevice('HRS-1234', 'Polar H10', -52, true),
            _FakeDevice('AA:BB:CC:DD:EE:01', 'Mi Band 8', -71, false),
          ],
          peers: const [_FakePeer('MAWJ 的手机', 'android', 3)],
          error: null,
          onScanBle: () async {},
          onConnectBle: (_) async => true,
          onConnectPeer: (_) async {},
          onConnectManual: (_) async => true,
        ),
      ),
      'connect',
    );
  });

  testWidgets('房间页截图', (tester) async {
    final series = _series();
    await _shoot(
      tester,
      Scaffold(
        backgroundColor: WinColors.bg,
        body: RoomView(
          transport: '局域网（MAWJ 的手机）',
          connected: true,
          members: [
            _member('m1', '甲', 72),
            _member('m2', '乙', 86),
            _member('m3', '丙', 0, online: false),
          ],
          liveBpm: (m) => m.online ? m.report.bpm : null,
          seriesFor: (_) => series,
          ownBpm: null,
          ownSeries: HeartRateSeries(),
          showBleRow: false,
        ),
      ),
      'room',
    );
  });

  testWidgets('设置页截图', (tester) async {
    await _shoot(
      tester,
      Scaffold(
        backgroundColor: WinColors.bg,
        body: SettingsView(
          transparent: true,
          onToggleTransparent: () {},
          logPath: r'C:\Users\MAWJ\AppData\Local\heartrate\logs\startup.log',
          onOpenLogs: () async {},
          safeMode: false,
          version: '1.0.10',
        ),
      ),
      'settings',
    );
  });

  testWidgets('悬浮窗截图', (tester) async {
    final series = _series();
    await _shoot(
      tester,
      Scaffold(
        backgroundColor: WinColors.bg,
        body: Center(
          child: Container(
            width: 420,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: WinColors.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(AppRadius.capsule),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _OverlayRow(name: '甲', bpm: 72, series: series),
                const SizedBox(height: 6),
                _OverlayRow(name: '乙', bpm: 96, series: series),
                const SizedBox(height: 6),
                _OverlayRow(
                  name: '丙',
                  bpm: null,
                  series: HeartRateSeries(),
                  offline: true,
                ),
              ],
            ),
          ),
        ),
      ),
      'overlay',
    );
  });
}

/// 与手机悬浮窗一行同形：名称 | 心率大字 | 迷你折线。
final class _OverlayRow extends StatelessWidget {
  const _OverlayRow({
    required this.name,
    required this.bpm,
    required this.series,
    this.offline = false,
  });
  final String name;
  final int? bpm;
  final HeartRateSeries series;
  final bool offline;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 96,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTextSize.caption,
            color: offline ? WinColors.textDim : Colors.white,
            shadows: const [Shadow(blurRadius: 3, color: Color(0xCC000000))],
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 44,
        child: Text(
          offline ? '离线' : (bpm == null ? '--' : '$bpm'),
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: AppTextSize.body,
            fontWeight: FontWeight.bold,
            color: offline ? WinColors.textDim : WinColors.accent,
            shadows: const [Shadow(blurRadius: 3, color: Color(0xCC000000))],
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 72,
        height: 22,
        child: CustomPaint(painter: WinSparklinePainter(series)),
      ),
    ],
  );
}

final class _FakeDevice {
  const _FakeDevice(this.id, this.name, this.rssi, this.isHrsCandidate);
  final String id;
  final String name;
  final int rssi;
  final bool isHrsCandidate;
}

final class _FakePeer {
  const _FakePeer(this.name, this.platform, this.members);
  final String name;
  final String platform;
  final int members;
}
