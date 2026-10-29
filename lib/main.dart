import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'core/logging/app_logger.dart';
import 'ui/app_state.dart';
import 'ui/pages/heart_rate_page.dart';
import 'ui/pages/room_page.dart';
import 'ui/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.instance.initialize();
  final state = AppState();
  runApp(HeartRateApp(state: state));
}

final class HeartRateApp extends StatefulWidget {
  const HeartRateApp({required this.state, super.key});
  final AppState state;
  @override
  State<HeartRateApp> createState() => _HeartRateAppState();
}

final class _HeartRateAppState extends State<HeartRateApp> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['Heart rate', 'Room', 'Settings'];
    final pages = [
      HeartRatePage(state: widget.state),
      RoomPage(state: widget.state),
      SettingsPage(state: widget.state),
    ];
    return MaterialApp(
      title: AppConfig.displayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.redAccent, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: Text(titles[_index])),
        body: SafeArea(child: IndexedStack(index: _index, children: pages)),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.favorite), label: 'Heart'),
            NavigationDestination(icon: Icon(Icons.groups), label: 'Room'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
