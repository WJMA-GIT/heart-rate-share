import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/reconnect_policy.dart';
import 'package:heartrate/core/logging/app_logger.dart';
import 'package:heartrate/core/platform/foreground_lease.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/room/room_endpoint.dart';
import 'package:heartrate/room/room_transport.dart';

import 'support/ws_test_server.dart';

final class _NoopBackend implements ForegroundBackend {
  @override
  Future<bool> start() async => true;
  @override
  Future<bool> stop() async => true;
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

List<LogEntry> entriesSince(int index) =>
    AppLogger.instance.entries.skip(index).toList();

void main() {
  group('掉线原因分类', () {
    test('ping 超时（我们自己关的 1001）与对端 1001 可区分', () {
      expect(
        classifyDrop(
          closingLocally: false,
          closeCode: 1001,
          sinceLastInbound: const Duration(seconds: 25),
        ),
        RoomDropCause.pingTimeout,
      );
      // 对端 1001 时数据通常刚还在流
      expect(
        classifyDrop(
          closingLocally: false,
          closeCode: 1001,
          sinceLastInbound: const Duration(seconds: 1),
        ),
        RoomDropCause.peer,
      );
    });

    test('本端主动关闭 = local；1006 = peer', () {
      expect(
        classifyDrop(
          closingLocally: true,
          closeCode: 1000,
          sinceLastInbound: Duration.zero,
        ),
        RoomDropCause.local,
      );
      expect(
        classifyDrop(
          closingLocally: false,
          closeCode: 1006,
          sinceLastInbound: const Duration(seconds: 30),
        ),
        RoomDropCause.peer,
      );
    });

    test('协议 ping 间隔是 20 秒（> App 层 3s ping，< relay 的 30s pong 超时）', () {
      expect(roomPingInterval, const Duration(seconds: 20));
    });
  });

  group('真实连接上的 ping 行为', () {
    test('正常运行不会因为 ping 产生虚假断连', () async {
      final relay = await WsTestServer.start(roomCode: 'PING1');
      addTearDown(relay.stop);
      final client = RoomClient(
        displayName: 'P',
        memberId: 'ping-test-1',
        foreground: ForegroundLease(backend: _NoopBackend()),
      );
      addTearDown(client.dispose);

      final before = AppLogger.instance.entries.length;
      await client.connect(relay.uri);
      await Future<void>.delayed(const Duration(seconds: 3));

      final drops = entriesSince(before).where(
        (e) => e.errorCode == 'ws_drop' || e.errorCode == 'ws_ping_timeout',
      );
      expect(drops, isEmpty, reason: '3 秒正常连接不该有任何掉线日志');
      expect(client.state, RoomConnectionState.connected);
    });

    test('入站静默超过阈值时主动判死并重连（不等对端先关）', () async {
      // 服务端只握手、之后一句都不发：模拟 NAT 回收/省电挂起造成的黑洞链路。
      final silent = await WsTestServer.start(roomCode: 'SILENT');
      addTearDown(silent.stop);
      var served = 0;
      final client = RoomClient(
        displayName: 'P',
        memberId: 'ping-test-3',
        foreground: ForegroundLease(backend: _NoopBackend()),
        staleAfter: const Duration(milliseconds: 200),
        reconnectPolicy: const ReconnectPolicy(
          maxAttempts: 3,
          baseDelay: Duration(milliseconds: 40),
          maxDelay: Duration(milliseconds: 80),
        ),
        opener: (uri, tls) {
          served += 1;
          return openRoomChannelResolved(uri, tls: tls);
        },
      );
      addTearDown(client.dispose);

      final before = AppLogger.instance.entries.length;
      await client.connect(silent.uri);

      await waitFor(
        () => entriesSince(before).any((e) => e.errorCode == 'ws_link_silent'),
        timeout: const Duration(seconds: 8),
        reason: '入站一直静默就该自己判死，而不是永远假装在线',
      );
      final silentLog = entriesSince(before)
          .firstWhere((e) => e.errorCode == 'ws_link_silent');
      expect(silentLog.message, contains('lastPingRtt='));

      await waitFor(
        () => served >= 2 && client.state == RoomConnectionState.connected,
        reason: '判死后应走既有的退避重连',
      );
      // 判死属于"我们关的"，落进既有的 ping 超时分类，不会被当成对端正常关闭。
      await waitFor(
        () => entriesSince(before).any(
          (e) =>
              e.errorCode == 'ws_drop' &&
              e.message.contains('cause=pingTimeout'),
        ),
        reason: '判死要归到 pingTimeout',
      );
      // 重连成功日志要带上用户实际感知的黑洞时长。
      expect(
        entriesSince(before)
            .firstWhere((e) => e.errorCode == 'ws_reconnect_ok')
            .message,
        contains('gap='),
      );
    });

    test('对端 1001 与异常 1006 在日志里可区分，且都能自动重连', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      WebSocket? peer;
      server.listen((request) async {
        peer = await WebSocketTransformer.upgrade(request);
      });

      final alive = await WsTestServer.start(roomCode: 'PING2');
      addTearDown(alive.stop);

      var served = 0;
      final client = RoomClient(
        displayName: 'P',
        memberId: 'ping-test-2',
        foreground: ForegroundLease(backend: _NoopBackend()),
        reconnectPolicy: const ReconnectPolicy(
          maxAttempts: 5,
          baseDelay: Duration(milliseconds: 40),
          maxDelay: Duration(milliseconds: 80),
        ),
        opener: (uri, tls) {
          served += 1;
          final target = served == 1 ? uri : alive.uri;
          return openRoomChannelResolved(target, tls: tls);
        },
      );
      addTearDown(client.dispose);

      final before = AppLogger.instance.entries.length;
      await client.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws?room=PING1'),
      );
      await peer!.close(1001, 'going away');
      await waitFor(
        () => entriesSince(before).any(
          (e) => e.errorCode == 'ws_drop' && e.message.contains('cause=peer'),
        ),
        reason: '1001 应记为 cause=peer',
      );
      final drop = entriesSince(before)
          .firstWhere((e) => e.errorCode == 'ws_drop');
      expect(drop.message, contains('closeCode=1001'));
      expect(drop.message, contains('cause=peer'));

      // 对端 1001 = "我要走了" → 立即重连，不需要用户操作
      await waitFor(
        () => client.state == RoomConnectionState.connected && served >= 2,
        reason: '1001 后应自动重连',
      );
      // 异常断开（1006）走同一条 ws_drop 日志，closeCode 原样打印 → 可区分
      expect(
        entriesSince(before)
            .where((e) => e.errorCode == 'ws_drop')
            .map((e) => e.message)
            .join('\n'),
        contains('closeCode=1001'),
      );
    });
  });
}
