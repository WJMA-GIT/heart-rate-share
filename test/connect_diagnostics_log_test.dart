import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/logging/app_logger.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_client.dart';

/// 导出日志必须自带现场：以前诊断块只出现在弹窗里，日志里只有一个 code。
void main() {
  test('连接失败时把完整诊断块写进会话日志', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.statusCode = 307;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        request.uri.toString(),
      );
      request.response.close();
    });

    final before = AppLogger.instance.entries.length;
    final client = RoomClient(displayName: 'T', memberId: 'log-test-member');
    addTearDown(client.dispose);

    await expectLater(
      client.connect(
        RoomAddress.parse('127.0.0.1:${server.port}', roomCode: 'LOGTEST'),
      ),
      throwsA(anything),
    );

    final entries = AppLogger.instance.entries.skip(before).toList();
    expect(
      entries.any(
        (entry) => entry.message.contains('WebSocket connect failed'),
      ),
      isTrue,
      reason: '至少要有失败摘要',
    );
    final block = entries.firstWhere(
      (entry) => entry.message.startsWith('connect diagnostics'),
      orElse: () => throw StateError('诊断块没有写进日志'),
    );
    // 关键字段必须都在
    for (final key in [
      'endpoint=',
      'result=',
      'tcp_reached=',
      'tls_ok=',
      'tls_evidence=',
      'error_type=',
      'root_error_type=',
      'attempt=',
      'http_probe=',
      'http_location=',
    ]) {
      expect(block.message, contains(key), reason: '缺少字段 $key');
    }
    expect(block.deviceId, 'log-test-member');
  });
}
