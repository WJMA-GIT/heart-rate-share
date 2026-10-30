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
        classifyRoomError(
          const HandshakeException('SSLV3_ALERT_HANDSHAKE_FAILURE'),
        ),
        RoomErrorCode.tlsHandshake,
      );
      // 明文端口常见的错误码：语义上属于"这个端口不是 TLS"
      expect(
        classifyRoomError(const HandshakeException('WRONG_VERSION_NUMBER')),
        RoomErrorCode.plaintextOnTlsPort,
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

    test('握手期被对端关闭/重置单独成类（真机上最容易落到 unknown 的一类）', () {
      expect(
        classifyRoomError(const SocketException('Connection reset by peer')),
        RoomErrorCode.tlsAborted,
      );
      // HttpException = HTTP 层已经开始解析（TLS 成功），不属于 tlsAborted
      expect(
        classifyRoomError(
          const HttpException(
            'Connection closed before full header was received',
          ),
        ),
        RoomErrorCode.handshakeRejected,
      );
      expect(
        classifyRoomError(
          const HandshakeException('Connection terminated during handshake'),
        ),
        RoomErrorCode.tlsAborted,
      );
    });

    test('明文响应（不是 TLS）单独成类', () {
      expect(
        classifyRoomError(
          const SocketException('Illegal request: HTTP/1.1 400 Bad Request'),
        ),
        RoomErrorCode.plaintextOnTlsPort,
      );
      expect(
        classifyRoomError(
          const TlsException('first record does not look like a TLS handshake'),
        ),
        RoomErrorCode.plaintextOnTlsPort,
      );
    });

    test('回探到的 HTTP 状态优先决定分类', () {
      HttpProbe probe(int status) => HttpProbe(scheme: 'https', status: status);
      expect(probe(302).code, RoomErrorCode.redirectedToLogin);
      expect(probe(301).code, RoomErrorCode.redirectedToLogin);
      expect(probe(401).code, RoomErrorCode.unauthorized);
      expect(probe(403).code, RoomErrorCode.forbidden);
      expect(probe(502).code, RoomErrorCode.badGateway);
      expect(probe(503).code, RoomErrorCode.serviceUnavailable);
      expect(probe(504).code, RoomErrorCode.gatewayTimeout);
      expect(probe(400).code, RoomErrorCode.badRequest);
      expect(probe(404).code, RoomErrorCode.endpointNotFound);
      expect(probe(101).code, isNull);
      expect(const HttpProbe(scheme: 'https', status: null).code, isNull);
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
      expect(
        classifyRoomError(StateError('whatever')),
        RoomErrorCode.unclassified,
      );
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
