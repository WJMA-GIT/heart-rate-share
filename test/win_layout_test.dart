import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/ui/widgets/heart_rate_chart.dart';
import 'package:heartrate/ui/win/win_app.dart';

/// 窗口能自由缩放之后，第一位的回归是「窄了会不会挤爆」：
/// - 设备表的 RSSI 是次要列，窄窗口要整列收掉；
/// - 房间卡片够宽才排两列，窄了单列。
///
/// 只断言布局规则本身，像素对齐留给真机截图。

final class _Device {
  _Device(this.name, this.rssi);
  final String name;
  final String id = 'dev-1';
  final int rssi;
  final bool isHrsCandidate = true;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void _sizeTo(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

ConnectView _connectView() => ConnectView(
  adapterState: 'on',
  bleBusy: 'idle',
  devices: [_Device('蓝牙设备 A', -60)],
  peers: const [],
  error: null,
  onScanBle: () async {},
  onConnectBle: (_) async => true,
  onConnectPeer: (_) async {},
  onConnectManual: (_) async => true,
);

RoomView _roomView(List<MemberState> members) => RoomView(
  transport: '局域网（手机）',
  connected: true,
  members: members,
  liveBpm: (member) => member.report.bpm,
  seriesFor: (_) => HeartRateSeries(),
  ownBpm: null,
  ownSeries: HeartRateSeries(),
  showBleRow: false,
);

MemberState _member(int index) => MemberState(
  report: HeartRateReport(
    memberId: 'm$index',
    displayName: '成员 $index',
    bpm: 70 + index,
    rrIntervalsMs: const [],
    sensorContact: true,
    sequence: index,
    measuredAt: DateTime.utc(2026, 10, 31, 12),
  ),
  lastSeen: DateTime.utc(2026, 10, 31, 12),
  online: true,
);

int _columns(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byType(GridView));
  final delegate =
      grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

void main() {
  testWidgets('设备表窄窗口收起 RSSI 列', (tester) async {
    _sizeTo(tester, 700, 600);
    await tester.pumpWidget(_host(_connectView()));
    expect(find.text('RSSI'), findsNothing);
    expect(find.text('蓝牙设备 A'), findsOneWidget);

    _sizeTo(tester, 1200, 800);
    await tester.pumpWidget(_host(_connectView()));
    expect(find.text('RSSI'), findsOneWidget);
  });

  testWidgets('房间卡片窄窗口单列', (tester) async {
    final members = [for (var i = 0; i < 3; i++) _member(i)];

    _sizeTo(tester, 800, 600);
    await tester.pumpWidget(_host(_roomView(members)));
    expect(_columns(tester), 1);

    _sizeTo(tester, 1400, 800);
    await tester.pumpWidget(_host(_roomView(members)));
    expect(_columns(tester), 2);
  });
}
