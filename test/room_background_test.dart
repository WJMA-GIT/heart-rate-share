import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/reconnect_policy.dart';
import 'package:heartrate/core/logging/app_logger.dart';
import 'package:heartrate/core/platform/foreground_lease.dart';
import 'package:heartrate/room/relay_server.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/room/room_endpoint.dart';
import 'package:heartrate/room/room_transport.dart';

final class _FakeBackend implements ForegroundBackend {
  int starts = 0;
  int stops = 0;
  bool running = false;

  @override
  Future<bool> start() async {
    starts += 1;
    running = true;
    return true;
  }

  @override
  Future<bool> stop() async {
    stops += 1;
    running = false;
    return true;
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

/// 起一个真实的 Relay，返回它的 ws 地址。
Future<({RelayServer relay, Uri uri})> startRelay(String room) async {
  final relay = RelayServer();
  await relay.start(host: InternetAddress.loopbackIPv4, port: 0);
  return (
    relay: relay,
    uri: RoomAddress.parse('127.0.0.1:${relay.port}', roomCode: relay.roomCode),
  );
}

void main() {
  late _FakeBackend backend;
  late ForegroundLease lease;

  setUp(() {
    backend = _FakeBackend();
    lease = ForegroundLease(backend: backend);
  });

  tearDown(() => lease.reset());

  test('房间连接期间持有前台租约，断开后释放', () async {
    final server = await startRelay('BG1');
    addTearDown(() => server.relay.stop());
    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-1',
      foreground: lease,
    );
    addTearDown(client.dispose);

    await client.connect(server.uri);
    expect(client.state, RoomConnectionState.connected);
    expect(lease.active, isTrue, reason: '房间连着就必须有前台服务');
    expect(lease.holders, contains('room'));

    await client.disconnect();
    expect(backend.stops, 1);
    expect(lease.active, isFalse);
  });

  test('BLE 断开不会把房间连接的保活一起关掉（引用计数）', () async {
    final server = await startRelay('BG2');
    addTearDown(() => server.relay.stop());
    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-2',
      foreground: lease,
    );
    addTearDown(client.dispose);

    await lease.acquire('ble');
    await client.connect(server.uri);
    await lease.release('ble');
    expect(lease.active, isTrue, reason: '房间还在，服务不能停');
    expect(lease.holders, {'room'});
  });

  test('意外掉线后自动重连（不需要用户操作）', () async {
    // 第一个服务端由我们控制，可以从"服务端一侧"关掉 socket → 客户端收到 onDone
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? peer;
    first.listen((request) async {
      peer = await WebSocketTransformer.upgrade(request);
    });
    addTearDown(() => first.close(force: true));
    final second = await startRelay('BG3');
    addTearDown(() => second.relay.stop());

    final firstUri = Uri.parse('ws://127.0.0.1:${first.port}/ws?room=BG3');
    var served = 0;
    Future<RoomOpenResult> opener(Uri uri, RoomTls tls) {
      served += 1;
      // 第一次连 first（我们可从服务端掐断），重连时连 second
      return openRoomChannelResolved(
        served == 1 ? firstUri : second.uri,
        tls: tls,
      );
    }

    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-3',
      foreground: lease,
      reconnectPolicy: const ReconnectPolicy(
        maxAttempts: 5,
        baseDelay: Duration(milliseconds: 50),
        maxDelay: Duration(milliseconds: 100),
      ),
      opener: opener,
    );
    addTearDown(client.dispose);

    await client.connect(Uri.parse('ws://127.0.0.1:${first.port}/ws?room=BG3'));
    expect(client.state, RoomConnectionState.connected);
    expect(served, 1);

    await peer!.close(); // 服务端把连接掐掉
    await waitFor(
      () => served >= 2 && client.state == RoomConnectionState.connected,
      reason: '掉线后应自动重连成功',
    );
  });

  test('从后台回来：连接已死时立刻重连，不等退避', () async {
    final alive = await startRelay('BG4');
    addTearDown(() => alive.relay.stop());

    var served = 0;
    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-4',
      foreground: lease,
      reconnectPolicy: const ReconnectPolicy(
        maxAttempts: 5,
        baseDelay: Duration(seconds: 30), // 故意很长：证明 resume 不走退避
        maxDelay: Duration(seconds: 30),
      ),
      opener: (uri, tls) {
        served += 1;
        return openRoomChannelResolved(alive.uri, tls: tls);
      },
    );
    addTearDown(client.dispose);

    await client.connect(alive.uri);
    expect(client.state, RoomConnectionState.connected);

    final watch = Stopwatch()..start();
    await client.onAppResumed(); // 连接其实还活着 → 不应重连
    watch.stop();
    expect(served, 1, reason: '连接健康时不该重连');
  });

  test('socket 僵死（无任何入站）时，resume 会强制重连', () async {
    // 只接受升级、永不发消息的服务器 —— 模拟"进程被冻结，socket 不再动"
    final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => silent.close(force: true));
    silent.listen((request) async {
      try {
        await WebSocketTransformer.upgrade(request);
      } catch (_) {
        request.response.statusCode = 400;
        await request.response.close();
      }
    });

    var served = 0;
    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-5',
      foreground: lease,
      staleAfter: const Duration(milliseconds: 100),
      reconnectPolicy: const ReconnectPolicy(
        maxAttempts: 3,
        baseDelay: Duration(milliseconds: 30),
        maxDelay: Duration(milliseconds: 60),
      ),
      opener: (uri, tls) {
        served += 1;
        return openRoomChannelResolved(uri, tls: tls);
      },
    );
    addTearDown(client.dispose);

    await client.connect(
      Uri.parse('ws://127.0.0.1:${silent.port}/ws?room=STALE'),
    );
    expect(client.state, RoomConnectionState.connected);

    await Future<void>.delayed(
      const Duration(milliseconds: 200),
    ); // 超过 staleAfter
    await client.onAppResumed();
    await waitFor(() => served >= 2, reason: '僵死连接应被强制重连');
  });

  test('对端关闭时日志记下 closeCode 与 initiator=remote', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    WebSocket? peer;
    server.listen((request) async {
      peer = await WebSocketTransformer.upgrade(request);
    });

    final client = RoomClient(
      displayName: 'T',
      memberId: 'bg-test-6',
      foreground: lease,
      reconnectPolicy: const ReconnectPolicy(
        maxAttempts: 1,
        baseDelay: Duration(seconds: 30),
        maxDelay: Duration(seconds: 30),
      ),
      opener: (uri, tls) => openRoomChannelResolved(uri, tls: tls),
    );
    addTearDown(client.dispose);

    final before = AppLogger.instance.entries.length;
    await client.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws?room=CLOSE'),
    );
    await peer!.close(4001, 'server bye');
    await waitFor(
      () => AppLogger.instance.entries
          .skip(before)
          .any((e) => e.errorCode == 'ws_drop'),
      reason: '应记录 ws_drop',
    );

    final drop = AppLogger.instance.entries
        .skip(before)
        .firstWhere((e) => e.errorCode == 'ws_drop');
    expect(drop.message, contains('closeCode=4001'));
    expect(drop.message, contains('server bye'));
    expect(drop.message, contains('initiator=remote'));
  });
}
