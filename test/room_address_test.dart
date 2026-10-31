import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_code.dart';

void main() {
  group('RoomAddress.parse', () {
    test('host without scheme gets ws and default port', () {
      expect(
        RoomAddress.parse('192.168.1.2', roomCode: 'ABC123').toString(),
        'ws://192.168.1.2:8765/ws?room=ABC123',
      );
    });

    test('domain without port uses default ws port', () {
      expect(
        RoomAddress.parse('heart.example.com', roomCode: 'ROOM01').toString(),
        'ws://heart.example.com:8765/ws?room=ROOM01',
      );
    });

    test('domain with explicit port is preserved', () {
      expect(
        RoomAddress.parse('heart.example.com:9443').toString(),
        'ws://heart.example.com:9443/ws',
      );
    });

    test('explicit ws scheme is accepted', () {
      expect(
        RoomAddress.parse('ws://heart.example.com:8765').toString(),
        'ws://heart.example.com:8765/ws',
      );
    });

    test('wss without port defaults to 443', () {
      expect(
        RoomAddress.parse('wss://heart.example.com').toString(),
        'wss://heart.example.com:443/ws',
      );
    });

    test('wss with explicit port is preserved', () {
      expect(
        RoomAddress.parse('wss://heart.example.com:8765').toString(),
        'wss://heart.example.com:8765/ws',
      );
    });

    test('room input overrides a room in the URL', () {
      expect(
        RoomAddress.parse(
          'wss://h.example.com?room=OLD',
          roomCode: 'NEW',
        ).queryParameters['room'],
        'NEW',
      );
    });

    test('normalized endpoint adds scheme and default port', () {
      expect(
        RoomAddress.normalizedEndpoint('192.168.1.10:8765'),
        'ws://192.168.1.10:8765',
      );
      expect(
        RoomAddress.normalizedEndpoint('heart.example.com'),
        'ws://heart.example.com:8765',
      );
      expect(
        RoomAddress.normalizedEndpoint('wss://heart.example.com'),
        'wss://heart.example.com:443',
      );
    });

    test('normalized endpoint drops path, query and room code', () {
      expect(
        RoomAddress.normalizedEndpoint(
          'wss://heart.example.com/ws?room=ABC123',
        ),
        'wss://heart.example.com:443',
      );
    });

    test('normalized endpoint rejects invalid input', () {
      expect(
        () => RoomAddress.normalizedEndpoint('http://localhost'),
        throwsA(isA<RoomAddressException>()),
      );
    });

    test('rejects empty, unsupported scheme, invalid host and port', () {
      expect(
        () => RoomAddress.parse(''),
        throwsA(
          isA<RoomAddressException>().having(
            (error) => error.reason,
            'reason',
            RoomAddressError.empty,
          ),
        ),
      );
      expect(
        () => RoomAddress.parse('http://localhost'),
        throwsA(
          isA<RoomAddressException>().having(
            (error) => error.reason,
            'reason',
            RoomAddressError.unsupportedScheme,
          ),
        ),
      );
      expect(
        () => RoomAddress.parse('ws://'),
        throwsA(
          isA<RoomAddressException>().having(
            (error) => error.reason,
            'reason',
            RoomAddressError.invalidHost,
          ),
        ),
      );
      expect(
        () => RoomAddress.parse('heart.example.com:70000'),
        throwsA(
          isA<RoomAddressException>().having(
            (error) => error.reason,
            'reason',
            RoomAddressError.invalidPort,
          ),
        ),
      );
      expect(
        () => RoomAddress.parse('heart.example.com:abc'),
        throwsA(
          isA<RoomAddressException>().having(
            (error) => error.reason,
            'reason',
            RoomAddressError.invalidPort,
          ),
        ),
      );
    });
  });

  test('IPv6 字面量：带方括号、裸地址、带端口都能解析', () {
    final bracketed = RoomAddress.parse('[::1]:8766', roomCode: 'R1');
    expect(bracketed.scheme, 'ws');
    expect(bracketed.host, '::1');
    expect(bracketed.port, 8766);
    expect(bracketed.queryParameters['room'], 'R1');

    final bare = RoomAddress.parse('::1');
    expect(bare.host, '::1');
    expect(bare.port, 8765);

    final secure = RoomAddress.parse('wss://[2001:db8::5]:8766');
    expect(secure.scheme, 'wss');
    expect(secure.host, '2001:db8::5');
    expect(secure.port, 8766);
  });

  test('IPv6 端点格式化会补方括号', () {
    expect(RoomAddress.bracket('::1'), '[::1]');
    expect(RoomAddress.bracket('[::1]'), '[::1]');
    expect(RoomAddress.bracket('mawj.asia'), 'mawj.asia');
    expect(
      RoomAddress.normalizedEndpoint('wss://[::1]:8766'),
      'wss://[::1]:8766',
    );
  });

  test('官方服务器必须 wss：裸域名纠正、显式 ws:// 拒绝', () {
    final bare = SecureEndpoint.parse('relay.mawj.asia');
    expect(bare.scheme, 'wss');
    expect(bare.host, 'relay.mawj.asia');
    expect(bare.port, 443);
    expect(bare.path, '/ws');

    final explicit = SecureEndpoint.parse('wss://relay.mawj.asia:8766');
    expect(explicit.port, 8766);

    expect(
      () => SecureEndpoint.parse('ws://relay.mawj.asia'),
      throwsA(
        isA<RoomAddressException>().having(
          (e) => e.reason,
          'reason',
          RoomAddressError.insecureScheme,
        ),
      ),
    );
  });

  test('裸地址带 :443 会自动按 wss 解析（明文打 443 必然失败）', () {
    final uri = RoomAddress.parse('relay.mawj.asia:443');
    expect(uri.scheme, 'wss');
    expect(uri.port, 443);
    // 不带端口的裸地址仍按局域网明文处理，保持旧行为
    expect(RoomAddress.parse('192.168.1.10').scheme, 'ws');
  });

  test('房间号必须符合字母数字下划线短横线且不超过 64 位', () {
    expect(RoomCode.isValid('ABC123'), isTrue);
    expect(RoomCode.isValid('a-b_c'), isTrue);
    expect(RoomCode.isValid('x' * 64), isTrue);
    expect(RoomCode.isValid('x' * 65), isFalse);
    expect(RoomCode.isValid('has space'), isFalse);
    expect(RoomCode.isValid('中文'), isFalse);
    expect(RoomCode.isValid(''), isFalse);
    expect(RoomCode.isValid(null), isFalse);

    expect(
      () => RoomAddress.parse('relay.mawj.asia:443', roomCode: 'has space'),
      throwsA(
        isA<RoomAddressException>().having(
          (e) => e.reason,
          'reason',
          RoomAddressError.invalidRoomCode,
        ),
      ),
    );
  });

  test('非标准端口 10086 在每一层都不能被丢掉', () {
    final uri = RoomAddress.parse(
      'wss://heart.mawj.asia:10086',
      roomCode: 'ABC123',
    );
    expect(uri.scheme, 'wss');
    expect(uri.host, 'heart.mawj.asia');
    expect(uri.port, 10086);
    expect(uri.path, '/ws');
    expect(uri.toString(), 'wss://heart.mawj.asia:10086/ws?room=ABC123');

    // 官方服务器解析（SecureEndpoint）同样保留端口
    final secure = SecureEndpoint.parse('heart.mawj.asia:10086');
    expect(secure.scheme, 'wss');
    expect(secure.port, 10086);

    // 格式化端点也不能吃掉端口
    expect(
      RoomAddress.normalizedEndpoint('wss://heart.mawj.asia:10086'),
      'wss://heart.mawj.asia:10086',
    );
  });

  group('RoomAddress.fromParts（两段式输入）', () {
    test('协议 + 地址 + 端口 → URI', () {
      expect(
        RoomAddress.fromParts(
          scheme: 'ws',
          host: '192.168.1.10',
          port: '8765',
          roomCode: 'ABC123',
        ).toString(),
        'ws://192.168.1.10:8765/ws?room=ABC123',
      );
      expect(
        RoomAddress.fromParts(
          scheme: 'WSS',
          host: 'heart.example.com',
          port: '10086',
          roomCode: 'R1',
        ).toString(),
        'wss://heart.example.com:10086/ws?room=R1',
      );
    });

    test('IPv6 字面量自动补方括号（带不带都行）', () {
      for (final host in ['2001:db8::5', '[2001:db8::5]']) {
        expect(
          RoomAddress.fromParts(
            scheme: 'ws',
            host: host,
            port: '8765',
            roomCode: 'R1',
          ).toString(),
          'ws://[2001:db8::5]:8765/ws?room=R1',
        );
      }
    });

    test('非法协议被拒绝', () {
      for (final scheme in ['http', 'ftp', '']) {
        expect(
          () => RoomAddress.fromParts(
            scheme: scheme,
            host: 'a.com',
            port: '80',
            roomCode: 'R1',
          ),
          throwsA(
            isA<RoomAddressException>().having(
              (e) => e.reason,
              'reason',
              RoomAddressError.unsupportedScheme,
            ),
          ),
        );
      }
    });

    test('非法端口被拒绝', () {
      for (final port in ['0', '65536', '-1', 'abc', '']) {
        expect(
          () => RoomAddress.fromParts(
            scheme: 'ws',
            host: 'a.com',
            port: port,
            roomCode: 'R1',
          ),
          throwsA(
            isA<RoomAddressException>().having(
              (e) => e.reason,
              'reason',
              RoomAddressError.invalidPort,
            ),
          ),
        );
      }
    });

    test('空地址被拒绝', () {
      expect(
        () => RoomAddress.fromParts(
          scheme: 'ws',
          host: '   ',
          port: '8765',
          roomCode: 'R1',
        ),
        throwsA(
          isA<RoomAddressException>().having(
            (e) => e.reason,
            'reason',
            RoomAddressError.invalidHost,
          ),
        ),
      );
    });
  });

  group('RoomCode.generate', () {
    test('长度 6、只用合法字符、多次不重复', () {
      final generated = <String>{};
      for (var i = 0; i < 200; i++) {
        final code = RoomCode.generate();
        expect(code, hasLength(6));
        expect(RoomCode.isValid(code), isTrue, reason: code);
        generated.add(code);
      }
      // 200 次生成至少要有多样性（不是为了测随机性，只是防止常量）
      expect(generated.length, greaterThan(150));
    });
  });
}
