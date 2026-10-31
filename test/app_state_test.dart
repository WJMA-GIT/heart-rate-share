import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/logging/app_logger.dart';
import 'package:heartrate/core/platform/room_overlay.dart';
import 'package:heartrate/core/profile/connection_profile.dart';
import 'package:heartrate/core/profile/install_identity.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/ui/app_state.dart';

import 'support/ws_test_server.dart';

final class _FakeOverlay implements RoomOverlayBackend {
  bool granted = false;
  int shows = 0;
  int updates = 0;
  int hides = 0;
  int requests = 0;
  double? lastAlpha;
  List<OverlayMember> lastMembers = const [];
  bool updateOk = true;
  bool hideOk = true;

  @override
  Future<bool> isPermissionGranted() async => granted;

  @override
  Future<bool> requestPermission() async {
    requests += 1;
    return granted;
  }

  @override
  Future<bool> show(List<OverlayMember> members, double alpha) async {
    shows += 1;
    lastMembers = members;
    lastAlpha = alpha;
    return true;
  }

  @override
  Future<bool> update(List<OverlayMember> members) async {
    updates += 1;
    lastMembers = members;
    return updateOk;
  }

  @override
  Future<bool> setAlpha(double alpha) async {
    lastAlpha = alpha;
    return true;
  }

  @override
  Future<bool> hide() async {
    hides += 1;
    return hideOk;
  }
}

Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, Object?> _member({
  required String id,
  required String name,
  required int bpm,
  bool online = true,
}) => {
  'memberId': id,
  'displayName': name,
  'bpm': bpm,
  'rrMs': <int>[],
  'sensorContact': null,
  'sequence': 1,
  'measuredAt': DateTime.now().toUtc().toIso8601String(),
  'lastSeen': DateTime.now().toUtc().toIso8601String(),
  'online': online,
};

ConnectionProfile _localServer(int port) => ConnectionProfile(
  mode: ConnectionMode.remote,
  host: '127.0.0.1',
  port: port,
  secure: false,
);

void main() {
  test('启动后不默认进入任何房间（必须显式创建或加入）', () {
    final state = AppState();
    addTearDown(state.dispose);
    expect(state.roomMode, isNull);
    expect(state.room.state, RoomConnectionState.disconnected);
    expect(state.recentProfiles, isEmpty);
    expect(state.currentRoomCode, isNull);
  });

  test('本机建房的历史记录被当作无效目标丢弃', () async {
    final store = InMemoryIdentityStore(
      connectionProfiles:
          '[{"mode":"local","host":"127.0.0.1","port":0,"secure":false,'
          '"path":"/ws","roomCode":"LOCAL1"}]',
    );
    final state = AppState(
      identityStore: store,
      recentProfiles: RecentProfiles.decode(
        await store.loadConnectionProfiles(),
      ),
    );
    addTearDown(state.dispose);
    expect(state.recentProfiles, isEmpty, reason: '本机房间不再是可连接目标');
  });

  test('删除一条最近记录会落盘', () async {
    final store = InMemoryIdentityStore();
    final profile = ConnectionProfile.official(roomCode: 'AAA111');
    final other = ConnectionProfile(
      mode: ConnectionMode.remote,
      host: '10.0.0.9',
      port: 8765,
      secure: false,
      roomCode: 'BBB222',
    );
    await store.saveConnectionProfiles(RecentProfiles.encode([profile, other]));
    final state = AppState(
      identityStore: store,
      recentProfiles: RecentProfiles.decode(
        await store.loadConnectionProfiles(),
      ),
    );
    addTearDown(state.dispose);

    await state.forgetProfile(profile);
    expect(state.recentProfiles.map((p) => p.id), [other.id]);
    final reloaded = RecentProfiles.decode(
      await store.loadConnectionProfiles(),
    );
    expect(reloaded.map((p) => p.id), [other.id]);
  });

  test('悬浮窗：开关打开才显示，成员变化只更新一次窗，离开房间立刻收掉', () async {
    final server = await WsTestServer.start(roomCode: 'OV1');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = true;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
    );
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV1');
    expect(state.room.state, RoomConnectionState.connected);
    expect(state.currentRoomCode, 'OV1');
    expect(overlay.shows, 0, reason: '用户没开开关时不能自己弹窗');

    await state.setOverlayEnabled(true);
    expect(overlay.shows, 1);

    server.broadcast('snapshot', {
      'members': [
        _member(id: 'm1', name: '甲', bpm: 72),
        _member(id: 'm2', name: '乙', bpm: 0, online: false),
      ],
    });
    await waitFor(() => overlay.lastMembers.length == 2, reason: '成员变化应更新悬浮窗');
    expect(overlay.shows, 1, reason: '更新不能叠出第二个窗口');
    expect(overlay.lastMembers.map((m) => m.name), ['甲', '乙']);
    expect(overlay.lastMembers.first.bpm, 72);
    expect(overlay.lastMembers.last.bpm, isNull, reason: '离线成员不能保留旧 BPM');

    final hides = overlay.hides;
    await state.disconnectRoom();
    await waitFor(() => overlay.hides > hides, reason: '离开房间要收掉窗口');
  });

  test('悬浮窗：没有权限时不显示，也不报错；重连后按偏好恢复', () async {
    final server = await WsTestServer.start(roomCode: 'OV2');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = false;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
      initialOverlayEnabled: true,
    );
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV2');
    await waitFor(() => !state.overlayVisible);
    expect(overlay.shows, 0, reason: '权限没给就只能降级');

    overlay.granted = true;
    await state.disconnectRoom();
    await state.connectProfile(_localServer(server.port), roomCode: 'OV2');
    await waitFor(() => overlay.shows >= 1, reason: '重连应按偏好恢复悬浮窗');
  });

  test('窗口被系统撤掉（原生 update 返回 false）后会自动重开', () async {
    final server = await WsTestServer.start(roomCode: 'OV3');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = true;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
    );
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV3');
    await state.setOverlayEnabled(true);
    expect(overlay.shows, 1);

    // 权限被系统撤销：原生侧 update 返回 false，重新 show 也会被拒绝
    overlay.updateOk = false;
    overlay.granted = false;
    server.broadcast('snapshot', {
      'members': [_member(id: 'm1', name: '甲', bpm: 66)],
    });
    await waitFor(() => !state.overlayVisible, reason: '原生说窗口没了就别再以为在显示');

    // 权限恢复后：下一次同步会重新开窗，而不是一直当作已显示
    overlay.granted = true;
    overlay.updateOk = true;
    final before = overlay.shows;
    server.broadcast('snapshot', {
      'members': [_member(id: 'm2', name: '乙', bpm: 70)],
    });
    await waitFor(
      () => overlay.shows > before && state.overlayVisible,
      reason: '恢复后应重新显示',
    );
  });

  test('窗口收不掉时不假装已收，下次同步继续收', () async {
    final server = await WsTestServer.start(roomCode: 'OV4');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()
      ..granted = true
      ..hideOk = false;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
    );
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV4');
    await state.setOverlayEnabled(true);
    expect(overlay.shows, 1);

    await state.disconnectRoom();
    await waitFor(() => overlay.hides >= 1);
    expect(state.overlayVisible, isTrue, reason: 'hide 没成功就不能认为已隐藏');

    overlay.hideOk = true;
    await state.connectProfile(_localServer(server.port), roomCode: 'OV4');
    await state.disconnectRoom();
    await waitFor(() => !state.overlayVisible, reason: '下一次同步要能收掉');
  });

  test('背景不透明度可以到 0；旧持久化值原样生效；内容永远不透明', () async {
    final store = InMemoryIdentityStore(overlayAlpha: 0.35);
    final state = AppState(
      identityStore: store,
      overlayBackend: _FakeOverlay(),
      initialOverlayEnabled: true,
      initialOverlayAlpha: await store.loadOverlayAlpha(),
    );
    addTearDown(state.dispose);

    expect(state.overlayAlpha, 0.35, reason: '旧值按背景不透明度原样映射');
    expect(OverlayDefaults.contentAlpha, 1.0, reason: '内容不透明度固定 100%');

    await state.setOverlayAlpha(0);
    expect(state.overlayAlpha, 0);
    expect(store.overlayAlpha, 0, reason: '0 = 背景全透明，要能存住');

    await state.setOverlayAlpha(2);
    expect(state.overlayAlpha, 1);
  });

  test('悬浮窗折线图：默认开、带归一化点，关掉即生效且落盘', () async {
    final server = await WsTestServer.start(roomCode: 'OV5');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = true;
    final store = InMemoryIdentityStore();
    final state = AppState(identityStore: store, overlayBackend: overlay);
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV5');
    await state.setOverlayEnabled(true);
    expect(state.overlayChart, isTrue, reason: '「显示折线图」默认开');

    server.broadcast('snapshot', {
      'members': [_member(id: 'm1', name: '甲', bpm: 72)],
    });
    await waitFor(
      () =>
          overlay.lastMembers.isNotEmpty &&
          overlay.lastMembers.first.points.isNotEmpty,
      reason: '开着折线图时每行都要带上这个成员的点',
    );
    final segment = overlay.lastMembers.first.points.first;
    expect(segment.length.isEven, isTrue);
    expect(segment.every((value) => value >= 0 && value <= 1), isTrue);

    await state.setOverlayChart(false);
    await waitFor(
      () => overlay.lastMembers.first.points.isEmpty,
      reason: '关掉后不再传点（原生侧就不画、也不占宽度）',
    );
    expect(store.overlayChart, isFalse);

    await state.setOverlayChart(true);
    await waitFor(() => overlay.lastMembers.first.points.isNotEmpty);
    expect(store.overlayChart, isTrue);
  });

  test('悬浮窗状态只在变化时写日志，不跟着每秒同步刷屏', () async {
    final server = await WsTestServer.start(roomCode: 'OV7');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = true;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
    );
    addTearDown(state.dispose);
    final before = AppLogger.instance.entries.length;

    await state.connectProfile(_localServer(server.port), roomCode: 'OV7');
    await state.setOverlayEnabled(true);
    expect(overlay.shows, 1);

    for (var i = 0; i < 3; i++) {
      server.broadcast('snapshot', {
        'members': [_member(id: 'm1', name: '甲', bpm: 70 + i)],
      });
      await waitFor(() => overlay.updates >= i + 1);
    }
    List<String> states() => [
      for (final entry in AppLogger.instance.entries.skip(before))
        if (entry.errorCode == 'overlay_state') entry.message,
    ];
    expect(
      states().where((line) => line.contains('state=shown')),
      hasLength(1),
      reason: '成员每秒变化，但状态没变就不能重复写',
    );

    await state.disconnectRoom();
    await waitFor(() => !state.overlayVisible);
    expect(states().last, contains('state=hidden'));
  });

  test('离线成员不画折线（不拿旧序列冒充在线）', () async {
    final server = await WsTestServer.start(roomCode: 'OV6');
    addTearDown(server.stop);
    final overlay = _FakeOverlay()..granted = true;
    final state = AppState(
      identityStore: InMemoryIdentityStore(),
      overlayBackend: overlay,
    );
    addTearDown(state.dispose);

    await state.connectProfile(_localServer(server.port), roomCode: 'OV6');
    await state.setOverlayEnabled(true);
    server.broadcast('snapshot', {
      'members': [_member(id: 'm1', name: '甲', bpm: 72)],
    });
    await waitFor(
      () =>
          overlay.lastMembers.isNotEmpty &&
          overlay.lastMembers.first.points.isNotEmpty,
    );

    server.broadcast('snapshot', {
      'members': [_member(id: 'm1', name: '甲', bpm: 0, online: false)],
    });
    await waitFor(
      () =>
          overlay.lastMembers.isNotEmpty &&
          overlay.lastMembers.first.bpm == null,
    );
    expect(overlay.lastMembers.first.points, isEmpty);
  });
}
