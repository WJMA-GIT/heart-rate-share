import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/config/app_config.dart';
import 'package:heartrate/core/profile/connection_profile.dart';
import 'package:heartrate/core/profile/install_identity.dart';
import 'package:heartrate/room/room_address.dart';

void main() {
  group('ConnectionProfile', () {
    test('官方服务器默认 wss://heart.mawj.asia:10086（非标准端口不能被丢掉）', () {
      final official = ConnectionProfile.official();
      expect(official.host, 'heart.mawj.asia');
      expect(official.port, 10086);
      expect(official.secure, isTrue);
      expect(official.scheme, 'wss');
      expect(official.endpoint, 'wss://heart.mawj.asia:10086');
      expect(
        official.toUri().toString(),
        'wss://heart.mawj.asia:10086/ws',
        reason: '拼连接串时端口必须保留',
      );
      expect(official.id, 'official|wss://heart.mawj.asia:10086');
    });

    test('备用线路默认不配置（不凭空给一个死地址）', () {
      expect(ConnectionProfile.officialSecondary(), isNull);
      expect(AppConfig.hasSecondaryServer, isFalse);
    });

    test('裸主机名会被纠正成 wss，写死 ws:// 直接拒绝', () {
      final corrected = ConnectionProfile.fromEndpoint('heart.mawj.asia');
      expect(corrected.scheme, 'wss');
      expect(corrected.port, 443);
      expect(
        () => ConnectionProfile.fromEndpoint('ws://heart.mawj.asia'),
        throwsA(isA<RoomAddressException>()),
      );
    });

    test('本机房间 id 稳定（端口每次变也不会刷出多条记录）', () {
      final a = ConnectionProfile.local();
      final b = ConnectionProfile.local().copyWith(port: 51234);
      expect(a.id, 'local');
      expect(b.id, 'local', reason: '端口变化不影响主键');
      expect(a.secure, isFalse);
      expect(a.toUri(portOverride: 45678).scheme, 'ws');
      expect(a.toUri(portOverride: 45678).port, 45678);
    });

    test('toUri 带房间号且走 /ws', () {
      final uri = ConnectionProfile.official(roomCode: 'ABC123').toUri();
      expect(uri.scheme, 'wss');
      expect(uri.host, 'heart.mawj.asia');
      expect(uri.port, 10086);
      expect(uri.path, '/ws');
      expect(uri.queryParameters['room'], 'ABC123');
      expect(uri.toString(), 'wss://heart.mawj.asia:10086/ws?room=ABC123');
    });

    test('IPv6 字面量端点带方括号', () {
      final profile = ConnectionProfile(
        mode: ConnectionMode.remote,
        host: '2001:db8::5',
        port: 8766,
        secure: true,
      );
      expect(profile.endpoint, 'wss://[2001:db8::5]:8766');
      expect(profile.toUri().toString(), contains('[2001:db8::5]'));
    });

    test('JSON 往返保持字段', () {
      final profile = ConnectionProfile(
        mode: ConnectionMode.remote,
        host: '192.168.1.10',
        port: 8765,
        secure: false,
        roomCode: 'R1',
        lastUsedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final back = ConnectionProfile.fromJson(profile.toJson())!;
      expect(back.id, profile.id);
      expect(back.roomCode, 'R1');
      expect(back.lastUsedAt, profile.lastUsedAt);
    });
  });

  group('RecentProfiles', () {
    final t0 = DateTime.utc(2026, 1, 1);

    test('同一条配置只保留一份并置顶，房间号会被新值覆盖', () {
      var list = <ConnectionProfile>[];
      list = RecentProfiles.touch(
        list,
        ConnectionProfile.official(roomCode: 'AAA111'),
        now: t0,
      );
      list = RecentProfiles.touch(
        list,
        ConnectionProfile.official(roomCode: 'BBB222'),
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(list, hasLength(1));
      expect(list.single.roomCode, 'BBB222');
      expect(list.single.lastUsedAt, t0.add(const Duration(minutes: 1)));
    });

    test('最多保留 6 条，最新的在最前', () {
      var list = <ConnectionProfile>[];
      for (var i = 0; i < 9; i++) {
        list = RecentProfiles.touch(
          list,
          ConnectionProfile(
            mode: ConnectionMode.remote,
            host: '10.0.0.$i',
            port: 8765,
            secure: false,
          ),
          now: t0.add(Duration(minutes: i)),
        );
      }
      expect(list, hasLength(RecentProfiles.maxEntries));
      expect(list.first.host, '10.0.0.8');
    });

    test('编码后能原样解回，脏数据不会让整份列表消失', () {
      final list = [
        ConnectionProfile.official(roomCode: 'AAA111'),
        ConnectionProfile.local(),
      ];
      final decoded = RecentProfiles.decode(RecentProfiles.encode(list));
      expect(decoded.map((p) => p.id), list.map((p) => p.id));

      expect(RecentProfiles.decode(null), isEmpty);
      expect(RecentProfiles.decode('not json'), isEmpty);
      expect(RecentProfiles.decode('[{"mode":"nope"}]'), isEmpty);
      // 一条坏一条好：好的要留下
      expect(
        RecentProfiles.decode(
          '[{"mode":"official","host":"mawj.asia","port":8766,"secure":true},'
          '{"mode":"bad"}]',
        ),
        hasLength(1),
      );
    });
  });

  group('与安装标识共用一套存储', () {
    test('最近连接配置和 installId/序号存在同一个 store 里', () async {
      final store = InMemoryIdentityStore();
      await store.saveInstallId('install-0001-aaaa-bbbb');
      await store.saveReservedSequence(120);
      await store.saveConnectionProfiles(
        RecentProfiles.encode([ConnectionProfile.official(roomCode: 'AAA111')]),
      );

      // 模拟 App 重启：同一份存储，新的启动流程读回来
      final installId = await store.loadInstallId();
      final reserved = await store.loadReservedSequence();
      final recents = RecentProfiles.decode(
        await store.loadConnectionProfiles(),
      );
      expect(installId, 'install-0001-aaaa-bbbb');
      expect(reserved, 120);
      expect(recents.single.roomCode, 'AAA111');
      expect(
        ConnectionProfile.official().secure,
        AppConfig.officialServerSecure,
      );
    });
  });
}
