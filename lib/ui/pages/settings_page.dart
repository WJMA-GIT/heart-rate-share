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
  late final TextEditingController _nicknameController;
  String? _nicknameError;
  bool _savingNickname = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.state.nickname);
    PackageInfo.fromPlatform()
        .then((info) {
          if (mounted) {
            setState(() => _version = '${info.version}+${info.buildNumber}');
          }
        })
        .catchError((_) {
          if (mounted) {
            setState(() => _version = Zh.versionUnavailable);
          }
        });
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _saveNickname() async {
    setState(() {
      _nicknameError = null;
      _savingNickname = true;
    });
    try {
      final validation = await widget.state.updateNickname(
        _nicknameController.text,
      );
      if (!mounted) return;
      if (validation != null) {
        setState(() => _nicknameError = Zh.nicknameError(validation));
        return;
      }
      _nicknameController.text = widget.state.nickname;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(Zh.nicknameSaved)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _nicknameError = Zh.nicknameSaveFailed);
    } finally {
      if (mounted) setState(() => _savingNickname = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      children: [
        Expanded(
          flex: state.debug.enabled ? 2 : 1,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _nicknameController,
                enabled: !_savingNickname,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: Zh.nicknameLabel,
                  hintText: Zh.nicknameHint,
                  helperText: Zh.nicknameHint,
                  errorText: _nicknameError,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _saveNickname(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _savingNickname ? null : _saveNickname,
                  icon: const Icon(Icons.save),
                  label: const Text(Zh.nicknameSave),
                ),
              ),
              const Divider(height: 32),
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
                        SnackBar(content: Text(Zh.exportError(error))),
                      );
                    }
                  }
                },
              ),
              const ListTile(
                title: Text(Zh.serverAddress),
                subtitle: Text(Zh.roomAddressHelp),
              ),
              ListTile(
                title: const Text(Zh.aboutVersion),
                subtitle: Text('$_version · ${AppConfig.applicationId}'),
              ),
            ],
          ),
        ),
        if (state.debug.enabled) ...[
          const Divider(height: 1),
          Expanded(flex: 3, child: DebugPanel(state: state)),
        ],
      ],
    );
  }
}
