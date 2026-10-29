import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../debug/debug_panel.dart';
import '../app_state.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});
  final AppState state;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  String _version = 'loading…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
    }).catchError((_) {
      if (mounted) setState(() => _version = 'unavailable (CI/native shell pending)');
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Debug diagnostics'),
          subtitle: const Text('Off by default; enables verbose local HRS logs'),
          value: state.debug.enabled,
          onChanged: state.debug.setEnabled,
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Export / share local logs'),
          subtitle: Text(state.logger.filePath ?? 'Log file is initialized at startup'),
          onTap: () async {
            try {
              await state.debug.shareLogs();
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $error')));
              }
            }
          },
        ),
        const ListTile(
          title: Text('Room address'),
          subtitle: Text('Set on the Room tab. Short code discovery and manual address are separate fields.'),
        ),
        ListTile(title: const Text('Version'), subtitle: Text('$_version · ${AppConfig.applicationId}')),
        const Divider(),
        if (state.debug.enabled) Expanded(child: DebugPanel(state: state)),
      ],
    );
  }
}
