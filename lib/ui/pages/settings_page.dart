import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/l10n/strings_zh.dart';
import '../../debug/debug_panel.dart';
import '../app_state.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});
  final AppState state;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  String _version = Zh.loadingVersion;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    }).catchError((_) {
      if (mounted) {
        setState(() => _version = Zh.versionUnavailable);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      children: [
        SwitchListTile(
          title: const Text(Zh.debugDiagnostics),
          subtitle: const Text(Zh.debugDescription),
          value: state.debug.enabled,
          onChanged: state.debug.setEnabled,
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text(Zh.exportLogs),
          subtitle: const Text(Zh.shareLogFile),
          onTap: () async {
            try {
              await state.debug.shareLogs();
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(Zh.exportError(error))));
              }
            }
          },
        ),
        const ListTile(
          title: Text(Zh.relayAddress),
          subtitle: Text(Zh.roomAddressHelp),
        ),
        ListTile(
            title: const Text(Zh.aboutVersion),
            subtitle: Text('$_version · ${AppConfig.applicationId}')),
        const Divider(),
        if (state.debug.enabled) Expanded(child: DebugPanel(state: state)),
      ],
    );
  }
}
