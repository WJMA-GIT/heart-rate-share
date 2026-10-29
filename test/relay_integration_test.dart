import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/room/relay_server.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_client.dart';

void main() {
  test('client report is broadcast through real WebSocket relay', () async {
    final relay = RelayServer();
    await relay.start(host: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(relay.stop);
    final client = RoomClient(displayName: 'CI');
    addTearDown(client.dispose);
    final first = client.members.firstWhere((members) => members.isNotEmpty);
    await client.connect(
      RoomAddress.parse('127.0.0.1:${relay.port}', roomCode: relay.roomCode),
    );
    client.report(bpm: 72, rrIntervalsMs: const [833], sensorContact: true);
    final members = await first.timeout(const Duration(seconds: 5));
    expect(members.single.report.bpm, 72);
    expect(members.single.online, isTrue);

    final renamed = client.members.firstWhere(
      (values) =>
          values.isNotEmpty && values.single.report.displayName == '新昵称',
    );
    client.updateDisplayName('新昵称');
    expect(
      (await renamed.timeout(const Duration(seconds: 5)))
          .single
          .report
          .displayName,
      '新昵称',
    );
  });

  test('protocol rejects incompatible version', () {
    expect(
      () => RoomEnvelope.fromJson({'v': 999, 'type': 'ping'}),
      throwsFormatException,
    );
  });
}
