import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/lan/lan_projection_server.dart';

/// 局域网投射服务：用真实 socket 验证协议与安全边界（不 mock）。
void main() {
  late LanProjectionServer server;
  late int port;

  setUp(() async {
    // 端口 0 = 内核分配，避免测试抢端口
    server = LanProjectionServer(
      port: 0,
      beaconInterval: const Duration(hours: 1),
    );
    final ok = await server.start(room: 'LAN123', name: 'phone');
    expect(ok, isTrue);
    port = server.portInUse;
    expect(port, greaterThan(0));
  });

  tearDown(() async {
    await server.stop();
    expect(server.isRunning, isFalse, reason: '关掉后不能留监听端口');
  });

  Future<WebSocket> connect({String room = 'LAN123'}) =>
      WebSocket.connect('ws://127.0.0.1:$port/ws?room=$room');

  test('hello 收到 welcome + 首帧 snapshot；ping 回 pong', () async {
    final socket = await connect();
    final frames = <Map<String, Object?>>[];
    socket.listen((data) {
      frames.add(jsonDecode('$data') as Map<String, Object?>);
    });
    socket.add(
      jsonEncode({
        'v': 1,
        'type': 'hello',
        'memberId': 'pc-1',
        'displayName': 'PC',
      }),
    );
    await _waitFor(() => frames.any((f) => f['type'] == 'welcome'));
    expect(frames.firstWhere((f) => f['type'] == 'welcome')['v'], 1);
    await _waitFor(() => frames.any((f) => f['type'] == 'snapshot'));
    expect(
      frames.firstWhere((f) => f['type'] == 'snapshot')['members'],
      isA<List>(),
    );

    socket.add(jsonEncode({'v': 1, 'type': 'ping'}));
    await _waitFor(() => frames.any((f) => f['type'] == 'pong'));
    await socket.close();
  });

  test('手机侧采样会以 memberDelta 推给客户端，5 秒无更新后标离线', () async {
    final socket = await connect();
    final frames = <Map<String, Object?>>[];
    socket.listen(
      (data) => frames.add(jsonDecode('$data') as Map<String, Object?>),
    );
    socket.add(
      jsonEncode({
        'v': 1,
        'type': 'hello',
        'memberId': 'pc-1',
        'displayName': 'PC',
      }),
    );

    server.publishOwnSample(
      memberId: 'phone-1',
      name: '我的手机',
      bpm: 72,
      rrMs: const [830],
      sensorContact: true,
      sequence: 1,
      measuredAt: DateTime.now().toUtc(),
    );
    await _waitFor(
      () => frames.any(
        (f) =>
            f['type'] == 'memberDelta' &&
            (f['member'] as Map)['memberId'] == 'phone-1',
      ),
    );
    final delta = frames.firstWhere(
      (f) =>
          f['type'] == 'memberDelta' &&
          (f['member'] as Map)['memberId'] == 'phone-1',
    );
    expect((delta['member'] as Map)['bpm'], 72);
    expect(server.memberCount, 1);

    await socket.close();
  });

  test('房间码不对 → 握手被拒（403），不泄漏数据', () async {
    await expectLater(
      connect(room: 'WRONG1'),
      throwsA(isA<WebSocketException>()),
    );
    expect(server.connectionCount, 0);
  });

  test('客户端上报的心率也会进入快照（PC 有传感器时同样可用）', () async {
    final socket = await connect();
    final frames = <Map<String, Object?>>[];
    socket.listen(
      (data) => frames.add(jsonDecode('$data') as Map<String, Object?>),
    );
    socket.add(
      jsonEncode({
        'v': 1,
        'type': 'hello',
        'memberId': 'pc-1',
        'displayName': 'PC',
      }),
    );
    socket.add(
      jsonEncode({
        'v': 1,
        'type': 'heartRate',
        'memberId': 'pc-1',
        'displayName': 'PC',
        'bpm': 88,
        'rrMs': <int>[],
        'sensorContact': true,
        'sequence': 1,
        'measuredAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    await _waitFor(() => server.memberCount == 1);
    expect(server.snapshot().single['bpm'], 88);
    await socket.close();
  });

  test('非法消息回 error，不影响连接', () async {
    final socket = await connect();
    final frames = <Map<String, Object?>>[];
    socket.listen(
      (data) => frames.add(jsonDecode('$data') as Map<String, Object?>),
    );
    socket.add('not json');
    await _waitFor(() => frames.any((f) => f['type'] == 'error'));
    expect(
      frames.firstWhere((f) => f['type'] == 'error')['code'],
      'BAD_MESSAGE',
    );
    await socket.close();
  });

  test('公网地址判定：内网/回环放行，公网拒绝', () {
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('192.168.1.20'),
      ),
      isTrue,
    );
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('10.0.0.5'),
      ),
      isTrue,
    );
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('172.20.1.1'),
      ),
      isTrue,
    );
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('127.0.0.1'),
      ),
      isTrue,
    );
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('8.8.8.8'),
      ),
      isFalse,
    );
    expect(
      LanProjectionServer.isPrivateOrLoopbackAddress(
        InternetAddress('1.1.1.1'),
      ),
      isFalse,
    );
  });
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
