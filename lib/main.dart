import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/config/app_config.dart';
import 'core/l10n/strings_zh.dart';
import 'core/logging/app_logger.dart';
import 'core/platform/room_overlay.dart';
import 'core/platform/startup_log.dart';
import 'core/profile/connection_profile.dart';
import 'core/profile/install_identity.dart';
import 'core/profile/user_profile_store.dart';
import 'room/sequence_counter.dart';
import 'ui/app_state.dart';
import 'ui/pages/heart_rate_page.dart';
import 'ui/pages/room_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/widgets/permission_gate.dart';
import 'ui/win/win_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面（Windows）走独立的悬浮窗界面：没有 BLE/悬浮窗服务/安装器这些 Android 能力，
  // 数据通路是「连手机的内网投射服务」，复用同一个 RoomClient 与折线画法。
  if (!kIsWeb && Platform.isWindows) {
    // 桌面：先接住所有 Dart 异常并落到 startup.log（和原生 runner 同一份），
    // 用户只要回传这一个文件就能定位"双击没反应"。
    StartupLog.attach(platform: 'windows');
    StartupLog.installHandlers();
    try {
      await runWinApp();
    } catch (error, stack) {
      StartupLog.info('fatal during startup: $error');
      StartupLog.info('$stack');
      rethrow;
    }
    return;
  }
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

  // 系统悬浮窗的偏好（开关 + 透明度）：读不到就用默认值，不挡启动。
  var overlayEnabled = false;
  var overlayAlpha = OverlayDefaults.defaultAlpha;
  var overlayChart = OverlayDefaults.defaultShowChart;
  try {
    overlayEnabled = await identityStore.loadOverlayEnabled();
    overlayAlpha = await identityStore.loadOverlayAlpha();
    overlayChart = await identityStore.loadOverlayChart();
  } catch (error, stack) {
    AppLogger.instance.error(
      'app',
      'Load overlay preference failed',
      null,
      error,
      stack,
    );
  }

  final state = AppState(
    nickname: savedNickname,
    initialOverlayEnabled: overlayEnabled,
    initialOverlayAlpha: overlayAlpha,
    initialOverlayChart: overlayChart,
    profileStore: profileStore,
    memberId: memberId,
    sequence: sequence,
    identityStore: identityStore,
    recentProfiles: recentProfiles,
  );
  // 手机侧「投射到局域网」默认开启：启动即按偏好拉起（失败只降级，不影响其他功能）。
  unawaited(state.startLanProjection());
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
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    // 断连复现时要能一眼看出当时是前台、息屏还是切了后台。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _navigatorKey.currentContext;
      if (context != null) ensureStartupPermissions(context);
    });
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
      HeartRatePage(state: widget.state),
      RoomPage(state: widget.state),
      SettingsPage(state: widget.state),
    ];
    return MaterialApp(
      navigatorKey: _navigatorKey,
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
