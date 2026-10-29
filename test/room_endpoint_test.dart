import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/relay_server.dart';
import 'package:heartrate/room/room_endpoint.dart';
import 'package:heartrate/room/room_transport.dart';

void main() {
  group('connectFirstAvailable（多地址回退）', () {
    final v6 = InternetAddress('2001:db8::1', type: InternetAddressType.IPv6);
    final v4 = InternetAddress('192.0.2.10', type: InternetAddressType.IPv4);

    test('首选地址失败会立刻换下一个，两次尝试都留痕', () async {
      final attempts = <RoomAttempt>[];
      final result = await connectFirstAvailable<String>(
        addresses: [v6, v4],
        perAddress: const Duration(seconds: 1),
        record: attempts.add,
        connect: (address) async {
          if (address.type == InternetAddressType.IPv6) {
            throw const SocketException('Network is unreachable');
          }
          return 'connected-${address.address}';
        },
      );

      expect(result, 'connected-192.0.2.10');
      expect(attempts, hasLength(2));
      expect(attempts.first.family, 'IPv6');
      expect(attempts.first.ok, isFalse);
      expect(attempts.first.errorCode, RoomErrorCode.ipv6Unreachable);
      expect(attempts.last.ok, isTrue);
    });

    test('单个地址超时不会拖住后面的地址', () async {
      final attempts = <RoomAttempt>[];
      final watch = Stopwatch()..start();
      final result = await connectFirstAvailable<String>(
        addresses: [v6, v4],
        perAddress: const Duration(milliseconds: 120),
        record: attempts.add,
        connect: (address) async {
          if (address.type == InternetAddressType.IPv6) {
            await Future<void>.delayed(const Duration(seconds: 5));
            return 'late';
          }
          return 'ipv4-ok';
        },
      );
      watch.stop();
      expect(result, 'ipv4-ok');
      expect(attempts.first.ok, isFalse);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: '要快速失败，不能让用户干等',
      );
    });

    test('全部失败时抛出最后一个错误', () async {
      await expectLater(
        connectFirstAvailable<String>(
          addresses: [v6, v4],
          perAddress: const Duration(seconds: 1),
          record: (_) {},
          connect: (address) async =>
              throw SocketException('refused ${address.address}'),
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('resolveHost', () {
    test('IPv6 字面量直接解析，不走 DNS', () async {
      final addresses = await resolveHost('::1');
      expect(addresses, hasLength(1));
      expect(addresses.single.type, InternetAddressType.IPv6);
      expect(addresses.single.address, '::1');
    });
  });

  group('RoomDiagnostics', () {
    test('端点里的 IPv6 必须方括号括起，文本可复制', () {
      const diagnostics = RoomDiagnostics(
        scheme: 'wss',
        host: 'mawj.asia',
        port: 8766,
        resolved: ['IPv6 2400:1234::1'],
        attempts: [
          RoomAttempt(
            address: '2400:1234::1',
            family: 'IPv6',
            elapsed: Duration(milliseconds: 42),
            errorName: 'Network is unreachable',
            errorCode: RoomErrorCode.ipv6Unreachable,
          ),
        ],
        code: RoomErrorCode.ipv6Unreachable,
      );
      final text = diagnostics.toClipboardText();
      expect(text, contains('result=ipv6Unreachable'));
      expect(text, contains('IPv6 2400:1234::1'));
      expect(text, contains('attempt=IPv6 2400:1234::1'));

      const literal = RoomDiagnostics(
        scheme: 'ws',
        host: '2001:db8::5',
        port: 8765,
        resolved: [],
        attempts: [],
        code: RoomErrorCode.unknown,
      );
      expect(literal.endpoint, 'ws://[2001:db8::5]:8765');
    });
  });

  group('IPv6 端到端', () {
    test('经 [::1] 字面量连上真实的 Relay（无 DNS、无 IPv4）', () async {
      final relay = RelayServer();
      try {
        await relay.start(host: InternetAddress.loopbackIPv6, port: 0);
      } on SocketException {
        markTestSkipped('当前环境没有 IPv6 loopback');
        return;
      }
      addTearDown(relay.stop);

      final opened = await openRoomChannelResolved(
        Uri.parse('ws://[::1]:${relay.port}/ws?room=${relay.roomCode}'),
        perAddress: const Duration(seconds: 3),
      );
      expect(opened.diagnostics.resolved.first, contains('IPv6'));
      expect(opened.diagnostics.resolved.first, contains('::1'));

      final messages = <String>[];
      final subscription = opened.channel.stream.listen(
        (data) => messages.add('$data'),
      );
      opened.channel.sink.add(
        '{"v":1,"type":"hello","memberId":"ipv6-test","displayName":"v6"}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(messages.any((m) => m.contains('welcome')), isTrue);

      await subscription.cancel();
      await opened.channel.sink.close();
    });
  });

  group('路径/房间号拼错时能分辨 400/404', () {
    test('服务器返回 404 时归类为 endpointNotFound', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('not found');
        request.response.close();
      });

      await expectLater(
        openRoomChannelResolved(
          Uri.parse('ws://127.0.0.1:${server.port}/ws?room=NOPE'),
          perAddress: const Duration(seconds: 2),
        ),
        throwsA(
          isA<RoomOpenException>().having(
            (e) => e.code,
            'code',
            RoomErrorCode.endpointNotFound,
          ),
        ),
      );
    });

    test('服务器返回 400 时归类为 badRequest', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('bad room');
        request.response.close();
      });

      await expectLater(
        openRoomChannelResolved(
          Uri.parse('ws://127.0.0.1:${server.port}/ws?room=BAD'),
          perAddress: const Duration(seconds: 2),
        ),
        throwsA(
          isA<RoomOpenException>().having(
            (e) => e.code,
            'code',
            RoomErrorCode.badRequest,
          ),
        ),
      );
    });
  });

  test('诊断信息里保留非标准端口', () {
    const diagnostics = RoomDiagnostics(
      scheme: 'wss',
      host: 'heart.mawj.asia',
      port: 10086,
      resolved: ['IPv6 2400:1234::9'],
      attempts: [],
      code: RoomErrorCode.certificateHostMismatch,
    );
    expect(diagnostics.endpoint, 'wss://heart.mawj.asia:10086');
    expect(
      diagnostics.toClipboardText(),
      contains('endpoint=wss://heart.mawj.asia:10086'),
    );
  });
}
