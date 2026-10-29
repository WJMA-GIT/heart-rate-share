import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/profile/connection_profile.dart';
import 'package:heartrate/core/profile/install_identity.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/ui/app_state.dart';

void main() {
  test('启动后不默认创建本机房间（必须显式二选一）', () {
    final state = AppState();
    addTearDown(state.dispose);
    expect(state.relay, isNull);
    expect(state.roomMode, isNull);
    expect(state.room.state, RoomConnectionState.disconnected);
    expect(state.recentProfiles, isEmpty);
  });

  test('本机房间是显式动作：起 relay、连上自己、写入最近列表并在重启后仍在', () async {
    final store = InMemoryIdentityStore();
    final first = AppState(identityStore: store);

    await first.createLocalRoom();
    expect(first.relay, isNotNull);
    expect(first.roomMode, ConnectionMode.local);
    expect(first.room.state, RoomConnectionState.connected);
    expect(first.recentProfiles.single.mode, ConnectionMode.local);

    // 落盘的是同一套 store（与安装标识共用）
    final saved = RecentProfiles.decode(await store.loadConnectionProfiles());
    expect(saved, hasLength(1));
    expect(saved.single.id, 'local');
    first.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 模拟 App 重启：新进程从同一份存储读回最近列表
    final second = AppState(
      identityStore: store,
      recentProfiles: RecentProfiles.decode(
        await store.loadConnectionProfiles(),
      ),
    );
    addTearDown(second.dispose);
    expect(second.recentProfiles.single.mode, ConnectionMode.local);
  });

  test('删除一条最近记录会落盘', () async {
    final store = InMemoryIdentityStore();
    final profile = ConnectionProfile.official(roomCode: 'AAA111');
    await store.saveConnectionProfiles(
      RecentProfiles.encode([profile, ConnectionProfile.local()]),
    );
    final state = AppState(
      identityStore: store,
      recentProfiles: RecentProfiles.decode(
        await store.loadConnectionProfiles(),
      ),
    );
    addTearDown(state.dispose);

    await state.forgetProfile(profile);
    expect(state.recentProfiles.map((p) => p.id), ['local']);
    final reloaded = RecentProfiles.decode(
      await store.loadConnectionProfiles(),
    );
    expect(reloaded.map((p) => p.id), ['local']);
  });
}
