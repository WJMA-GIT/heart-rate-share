import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/room_address.dart';

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
}
