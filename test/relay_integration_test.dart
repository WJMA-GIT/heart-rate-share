import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/profile/install_identity.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/room/relay_server.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/room/sequence_counter.dart';

/// 轮询等待条件成立，避免固定 sleep 造成抖动。
Future<void> waitUntil(
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

  test('同一安装标识重进房间：不新增成员，旧连接下线，序号继续递增', () async {
    final relay = RelayServer();
    await relay.start(host: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(relay.stop);
    final uri = RoomAddress.parse(
      '127.0.0.1:${relay.port}',
      roomCode: relay.roomCode,
    );
    const installId = 'install-0001-aaaa-bbbb';

    // 本地持久化（同一份"磁盘"），模拟两次 App 启动。
    final store = InMemoryIdentityStore();

    final first = RoomClient(
      displayName: '张三',
      memberId: installId,
      sequence: await SequenceCounter.restore(store, block: 5),
    );
    await first.connect(uri);
    first.report(bpm: 70, rrIntervalsMs: const [857], sensorContact: true);
    await waitUntil(
      () =>
          relay.store.members.length == 1 &&
          relay.store.members.single.report.bpm == 70,
      reason: '第一次进房的成员应出现在房间成员表',
    );
    final sequenceBeforeRestart = relay.store.members.single.report.sequence;

    // 关掉 App
    await first.dispose();
    expect(relay.store.members, hasLength(1), reason: '关掉连接后成员仍在 2 分钟保留期内');

    // 重新打开 App：同一安装标识、同一份序号存储
    final second = RoomClient(
      displayName: '张三',
      memberId: installId,
      sequence: await SequenceCounter.restore(store, block: 5),
    );
    addTearDown(second.dispose);
    await second.connect(uri);
    second.report(bpm: 80, rrIntervalsMs: const [750], sensorContact: true);
    await waitUntil(
      () =>
          relay.store.members.length == 1 &&
          relay.store.members.single.report.bpm == 80,
      reason: '重进后应复用同一个成员并刷新心率',
    );

    final member = relay.store.members.single;
    expect(member.report.memberId, installId);
    expect(member.report.displayName, '张三');
    expect(
      member.report.sequence > sequenceBeforeRestart,
      isTrue,
      reason: '重启后序号必须继续递增，否则上报会被当旧包丢弃',
    );
    expect(member.online, isTrue, reason: '短暂重连不该被判离线');
  });
}
