import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/config/app_config.dart';
import 'core/l10n/strings_zh.dart';
import 'core/logging/app_logger.dart';
import 'core/profile/connection_profile.dart';
import 'core/profile/install_identity.dart';
import 'core/profile/user_profile_store.dart';
import 'room/sequence_counter.dart';
import 'ui/app_state.dart';
import 'ui/pages/heart_rate_page.dart';
import 'ui/pages/room_page.dart';
import 'ui/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var appVersion = '';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // 拿不到版本不该挡住启动；日志里会显示 unknown。
  }
  await AppLogger.instance.initialize(version: appVersion);

  UserProfileStore profileStore = InMemoryUserProfileStore();
  IdentityStore identityStore = InMemoryIdentityStore();
  String? savedNickname;
  try {
    final preferences = await SharedPreferences.getInstance();
    profileStore = SharedPreferencesUserProfileStore(preferences);
    identityStore = SharedPreferencesIdentityStore(preferences);
    savedNickname = await profileStore.loadNickname();
  } catch (error, stack) {
    AppLogger.instance.error(
      'profile',
      'Load nickname failed: $error',
      null,
      error,
      stack,
    );
  }

  // 安装标识：重启 App 后必须还是同一个值，否则服务端会把回来的用户当成新成员。
  final memberId = await _loadOrCreateInstallId(identityStore);
  final sequence = await SequenceCounter.restore(identityStore);

  // 最近连接配置与安装标识共用同一套本地存储；坏了就当空列表，不挡启动。
  var recentProfiles = const <ConnectionProfile>[];
  try {
    recentProfiles = RecentProfiles.decode(
      await identityStore.loadConnectionProfiles(),
    );
  } catch (error, stack) {
    AppLogger.instance.error(
      'room',
      'Load recent profiles failed',
      null,
      error,
      stack,
    );
  }

  final state = AppState(
    nickname: savedNickname,
    profileStore: profileStore,
    memberId: memberId,
    sequence: sequence,
    identityStore: identityStore,
    recentProfiles: recentProfiles,
  );
  runApp(HeartRateApp(state: state));
}

/// 读本地安装标识；没有就生成一个并落盘。失败也不能挡住启动：
/// 退化为本次进程内有效的随机标识（服务端会当成新成员，但功能可用）。
Future<String> _loadOrCreateInstallId(IdentityStore store) async {
  try {
    final saved = await store.loadInstallId();
    if (InstallId.isValid(saved)) {
      AppLogger.instance.info(
        'identity',
        'install id loaded (same install reusing member identity)',
        deviceId: saved!.trim(),
        code: 'install_id_loaded',
      );
      return saved.trim();
    }
    final created = InstallId.generate();
    await store.saveInstallId(created);
    AppLogger.instance.info(
      'identity',
      'install id created (first launch or cleared data)',
      deviceId: created,
      code: 'install_id_created',
    );
    return created;
  } catch (error, stack) {
    AppLogger.instance.error(
      'identity',
      'Install id load failed',
      null,
      error,
      stack,
    );
    return InstallId.generate();
  }
}

final class HeartRateApp extends StatefulWidget {
  const HeartRateApp({required this.state, super.key});
  final AppState state;
  @override
  State<HeartRateApp> createState() => _HeartRateAppState();
}

final class _HeartRateAppState extends State<HeartRateApp>
    with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    // 断连复现时要能一眼看出当时是前台、息屏还是切了后台。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogger.instance.info('app', 'lifecycle=${state.name}');
    widget.state.onAppLifecycle(state);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_changed);
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const titles = [Zh.heartRateTitle, Zh.roomTitle, Zh.settingsTitle];
    final pages = [
      HeartRatePage(
        state: widget.state,
        onSwitchRoom: () => setState(() => _index = 1),
      ),
      RoomPage(state: widget.state),
      SettingsPage(state: widget.state),
    ];
    return MaterialApp(
      title: AppConfig.displayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.redAccent, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: Text(titles[_index])),
        body: SafeArea(
          child: IndexedStack(index: _index, children: pages),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.favorite),
              label: Zh.navHeartRate,
            ),
            NavigationDestination(icon: Icon(Icons.groups), label: Zh.navRoom),
            NavigationDestination(
              icon: Icon(Icons.settings),
              label: Zh.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}
