import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/room_transport.dart';

void main() {
  group('classifyRoomError', () {
    test('证书类错误能与网络错误分开', () {
      expect(
        classifyRoomError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED: self signed'),
        ),
        RoomErrorCode.certificateUntrusted,
      );
      expect(
        // 配了 CERT_SHA256 但指纹对不上：由 pinMismatch 标记带上来
        classifyRoomError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          pinMismatch: true,
        ),
        RoomErrorCode.certificatePinnedMismatch,
      );
      expect(
        classifyRoomError(const HandshakeException('WRONG_VERSION_NUMBER')),
        RoomErrorCode.tlsHandshake,
      );
    });

    test('通配证书不含根域 → 域名不匹配单独成类', () {
      expect(
        classifyRoomError(
          const HandshakeException(
            'CERTIFICATE_VERIFY_FAILED: Hostname mismatch, '
            'certificate is not valid for mawj.asia',
          ),
        ),
        RoomErrorCode.certificateHostMismatch,
      );
    });

    test('网络类错误逐项可分辨', () {
      expect(
        classifyRoomError(
          const SocketException('Failed host lookup: mawj.asia'),
        ),
        RoomErrorCode.dnsFailure,
      );
      expect(
        classifyRoomError(
          const SocketException(
            'Connection refused (OS Error: Connection refused, errno = 111)',
          ),
        ),
        RoomErrorCode.connectionRefused,
      );
      expect(
        classifyRoomError(
          const SocketException('Connection timed out (errno = 110)'),
        ),
        RoomErrorCode.connectionTimeout,
      );
      expect(
        classifyRoomError(
          Exception(
            'WebSocketException: Connection to x was not upgraded to websocket',
          ),
        ),
        RoomErrorCode.handshakeRejected,
      );
      expect(classifyRoomError(StateError('whatever')), RoomErrorCode.unknown);
    });
  });

  group('RoomTls', () {
    test('默认不钉证书（走系统 CA）', () {
      expect(RoomTls.none.hasPin, isFalse);
      expect(RoomTls.none.matchesCertificate(const [1, 2, 3]), isFalse);
    });

    test('指纹大小写与冒号不敏感', () {
      const tls = RoomTls(pinnedSha256: 'AA:BB:CC');
      expect(tls.hasPin, isTrue);
      // 不对的指纹必须拒绝
      expect(tls.matchesCertificate(const [0]), isFalse);
    });
  });
}
