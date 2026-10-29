import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/room_address.dart';

void main() {
  test('manual host gets default port, path, and room', () {
    expect(RoomAddress.parse('192.168.1.2', roomCode: 'ABC123').toString(),
        'ws://192.168.1.2:8765/ws?room=ABC123');
  });
  test('rejects non-WebSocket and empty addresses', () {
    expect(() => RoomAddress.parse('http://localhost'), throwsFormatException);
    expect(() => RoomAddress.parse(''), throwsFormatException);
  });
}
