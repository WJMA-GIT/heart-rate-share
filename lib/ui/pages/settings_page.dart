import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/l10n/strings_zh.dart';
import '../../core/platform/app_permissions.dart';
import '../../core/platform/room_overlay.dart';
import '../../core/update/update_installer.dart';
import '../../debug/debug_panel.dart';
import '../../room/room_client.dart';
import '../app_state.dart';
import '../version_tap.dart';
import '../widgets/update_tile.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});
  final AppState state;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  String _version = Zh.loadingVersion;
  late final TextEditingController _nicknameController;
  final _versionTaps = VersionTapGate();
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

  /// 版本号连点 5 次（相邻间隔 3 秒内）才打开诊断面板，取代原来的显式开关。
  void _onVersionTap() {
    if (!_versionTaps.tap()) return;
    widget.state.debug.setEnabled(true);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(Zh.debugEnabledByTaps)));
  }

  /// 悬浮窗开关：只在用户主动打开时申请权限；拒绝/不支持就降级为不显示。
  Future<void> _toggleOverlay(bool value) async {
    final state = widget.state;
    if (value) {
      final granted = await state.ensureOverlayPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Zh.overlayPermissionDenied)),
        );
        return;
      }
    }
    await state.setOverlayEnabled(value);
    if (!mounted || !value || state.overlayVisible) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(Zh.overlayShownWhenJoined)));
  }

  /// 权限状态 + 「去设置」入口：拒绝后唯一的补救路径，不再弹窗骚扰。
  Widget _permissionsTile(BuildContext context) {
    return FutureBuilder<PermissionState>(
      future: AppPermissions.check(),
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null || state.allGranted) {
          return const SizedBox.shrink();
        }
        return Card(
          elevation: 0,
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text(Zh.permissionDeniedTitle),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!state.notifications)
                  const Text(Zh.permissionDeniedNotifications),
                if (!state.bluetooth) const Text(Zh.permissionDeniedBluetooth),
              ],
            ),
            trailing: TextButton(
              onPressed: AppPermissions.openAppSettings,
              child: const Text(Zh.openAppSettings),
            ),
          ),
        );
      },
    );
  }

  /// 系统悬浮窗：开关 + 背景不透明度（可到 0）+ 显示折线图。
  Widget _overlayTile(BuildContext context) {
    final state = widget.state;
    final percent = (state.overlayAlpha * 100).round();
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.picture_in_picture_alt_outlined),
            title: const Text(Zh.overlayTitle),
            subtitle: const Text(Zh.overlayBody),
            isThreeLine: true,
            value: state.overlayEnabled,
            onChanged: _toggleOverlay,
          ),
          if (state.overlayEnabled &&
              state.room.state == RoomConnectionState.connected &&
              !state.overlayVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      Zh.overlayNotVisible,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: state.retryOverlay,
                    child: const Text(Zh.overlayRetry),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(Zh.overlayAlphaLabel),
                Expanded(
                  child: Slider(
                    value: state.overlayAlpha,
                    min: OverlayDefaults.minAlpha,
                    max: 1,
                    divisions: 20,
                    label: '$percent%',
                    onChanged: state.overlayEnabled
                        ? state.previewOverlayAlpha
                        : null,
                    onChangeEnd: state.overlayEnabled
                        ? state.setOverlayAlpha
                        : null,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('$percent%', textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                Zh.overlayAlphaHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.show_chart),
            title: const Text(Zh.overlayChartTitle),
            subtitle: const Text(Zh.overlayChartBody),
            value: state.overlayChart,
            onChanged: state.overlayEnabled ? state.setOverlayChart : null,
          ),
        ],
      ),
    );
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
              _permissionsTile(context),
              if (PlatformRoomOverlay.supported) _overlayTile(context),
              // 检查更新只在 Android 上有意义（安装器/签名校验都是平台能力）。
              if (PlatformUpdateInstaller.supported) const UpdateTile(),
              const Divider(height: 24),
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
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text(Zh.aboutVersion),
                subtitle: Text('$_version · ${AppConfig.applicationId}'),
                onTap: _onVersionTap,
              ),
              if (state.debug.enabled)
                const Padding(
                  padding: EdgeInsets.only(left: 16, top: 4),
                  child: Text(Zh.debugPanelHint),
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
