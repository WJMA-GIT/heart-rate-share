import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/room_endpoint.dart';
import 'package:heartrate/room/room_transport.dart';
import 'package:web_socket_channel/io.dart';

/// 自签证书（test-only，10 年有效）：CN=localhost，SAN 覆盖 localhost 与 127.0.0.1。
/// 指纹用于"钉扎"路径，证明客户端的 TLS 校验回调真的被执行过。
const _pinnedSha256 =
    '4472afd6779e699c61b592e496b6b2d9d3c41b2e7c542bc5606167fa58ca04e9';

Future<HttpServer> _startTlsWsServer() async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/tls/localhost-cert.pem')
    ..usePrivateKey('test/fixtures/tls/localhost-key.pem');
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  server.listen((request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('{"v":1,"type":"welcome"}');
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  });
  return server;
}

void main() {
  group('wss 必须真的走 TLS（回归：connectionFactory 曾返回明文 socket）', () {
    test('自签证书 + 指纹钉扎：能连上，且校验回调确实执行（= 真的做了 TLS）', () async {
      final server = await _startTlsWsServer();
      addTearDown(() => server.close(force: true));

      final opened = await openRoomChannelResolved(
        Uri.parse('wss://127.0.0.1:${server.port}/ws?room=TEST01'),
        tls: const RoomTls(pinnedSha256: _pinnedSha256),
        perAddress: const Duration(seconds: 5),
      );
      addTearDown(() => opened.channel.sink.close());

      final messages = <String>[];
      opened.channel.stream.listen((data) => messages.add('$data'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(messages.any((m) => m.contains('welcome')), isTrue);
      expect(opened.diagnostics.resolved.first, contains('IPv4'));
    });

    test('不钉指纹时必须证书校验失败 —— 明文字节不可能产生证书错误', () async {
      final server = await _startTlsWsServer();
      addTearDown(() => server.close(force: true));

      RoomOpenException? failure;
      try {
        await openRoomChannelResolved(
          Uri.parse('wss://127.0.0.1:${server.port}/ws?room=TEST01'),
          perAddress: const Duration(seconds: 5),
        );
      } on RoomOpenException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull, reason: '自签证书在系统 CA 下必须失败');
      expect(
        failure!.code,
        anyOf(
          RoomErrorCode.certificateUntrusted,
          RoomErrorCode.certificateHostMismatch,
        ),
        reason: '证书类错误只能来自真实的 TLS 握手',
      );
      final text = failure.diagnostics.toClipboardText();
      expect(text, contains('tls_ok='));
      expect(text, isNot(contains('result=plaintextOnTlsPort')));
    });

    test('明文 ws 打 TLS 端口必然失败（证明该端口只接受 TLS）', () async {
      final server = await _startTlsWsServer();
      addTearDown(() => server.close(force: true));

      Object? error;
      try {
        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.port}/ws?room=TEST01'),
        );
        await channel.ready.timeout(const Duration(seconds: 5));
        await channel.sink.close();
      } on Object catch (caught) {
        error = caught;
      }
      expect(error, isNotNull, reason: 'TLS 端口不该接受明文 WebSocket');
    });

    test('wss 连明文端口 → plaintextOnTlsPort（真实连接在 TLS 层失败）', () async {
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plain.close(force: true));
      plain.listen((request) {
        request.response.statusCode = 200;
        request.response.write('plain http');
        request.response.close();
      });

      RoomOpenException? failure;
      try {
        await openRoomChannelResolved(
          Uri.parse('wss://127.0.0.1:${plain.port}/ws?room=TEST01'),
          perAddress: const Duration(seconds: 3),
        );
      } on RoomOpenException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(failure!.code, RoomErrorCode.plaintextOnTlsPort);
      final text = failure.diagnostics.toClipboardText();
      expect(text, contains('result=plaintextOnTlsPort'));
      expect(text, contains('tls_ok=no'));
    });
  });
}
