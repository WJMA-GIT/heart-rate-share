import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
import '../../core/config/app_config.dart';
import '../../core/profile/connection_profile.dart';
import '../../room/room_code.dart';
import '../../room/room_address.dart';
import '../../room/room_client.dart';
import '../app_state.dart';
import '../widgets/connect_failure.dart';

final class RoomPage extends StatefulWidget {
  const RoomPage({required this.state, super.key});
  final AppState state;
  @override
  State<RoomPage> createState() => _RoomPageState();
}

final class _RoomPageState extends State<RoomPage> {
  late final TextEditingController _address;
  final _roomCode = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 地址框只在「高级」里出现，默认不预填官方地址（界面上不露出它）。
    _address = TextEditingController();
  }

  @override
  void dispose() {
    _address.dispose();
    _roomCode.dispose();
    super.dispose();
  }

  /// 只有通过 `^[A-Za-z0-9_-]{1,64}$` 才算有效房间号：先在本地拦住，
  /// 免得拼进 URL 后拿 400/404 回来再猜。
  String? get _typedRoom => RoomCode.normalize(_roomCode.text);

  bool get _roomCodeLooksInvalid =>
      _roomCode.text.trim().isNotEmpty && !RoomCode.isValid(_roomCode.text);

  bool _requireRoomCode() {
    if (_typedRoom != null) return true;
    final message = _roomCodeLooksInvalid
        ? Zh.roomError(
            const RoomAddressException(RoomAddressError.invalidRoomCode),
          )
        : Zh.roomNumberRequired;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    return false;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        final code = widget.state.room.lastErrorCode;
        final diagnostics = widget.state.room.lastDiagnostics;
        final message = code == null
            ? Zh.roomError(error)
            : Zh.roomErrorCode(code);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
            action: diagnostics == null
                ? null
                : SnackBarAction(
                    label: Zh.seeDiagnostics,
                    onPressed: () => showConnectFailure(
                      context,
                      message: message,
                      diagnostics: diagnostics.toClipboardText(),
                    ),
                  ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 官方服务器：需要房间号（可用最近记录里的，或用户手填）。
  Future<void> _connectOfficial() async {
    final code = _typedRoom;
    if (!_requireRoomCode()) return;
    await _run(
      () => widget.state.connectProfile(
        ConnectionProfile.official(),
        roomCode: code,
      ),
    );
  }

  /// 本机房间：起 Relay 再自己连进去（显式动作，绝不默认发生）。
  Future<void> _createLocalRoom() => _run(widget.state.createLocalRoom);

  Future<void> _connectRecent(ConnectionProfile profile) async {
    if (profile.mode == ConnectionMode.local) {
      await _run(widget.state.createLocalRoom);
      return;
    }
    final code = _typedRoom ?? profile.roomCode;
    if (!RoomCode.isValid(code) && !_requireRoomCode()) return;
    await _run(() => widget.state.connectProfile(profile, roomCode: code));
  }

  /// 高级：手动地址（ws:// 或 wss:// 都行），沿用原来的解析器。
  void _fillSecondary(String endpoint) {
    setState(() => _address.text = endpoint);
  }

  Future<void> _connectManual() async {
    final raw = _address.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(Zh.serverAddressHint)));
      return;
    }
    final code = _typedRoom;
    if (!_requireRoomCode()) return;
    await _run(() async {
      final uri = RoomAddress.parse(raw, roomCode: code);
      await widget.state.connectProfile(
        ConnectionProfile(
          mode: ConnectionMode.remote,
          host: uri.host,
          port: uri.port,
          secure: uri.scheme == 'wss',
        ),
        roomCode: code,
      );
    });
  }

  Future<void> _copyRoomCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(Zh.roomCodeCopied)));
  }

  /// 主界面一律用友好命名：官方服务器 / 本机房间 / 自定义服务器。
  /// 具体 IP、端口不铺在列表上，要看细节走"连接详情"弹窗。
  String _profileLabel(ConnectionProfile profile) => switch (profile.mode) {
    ConnectionMode.official => Zh.officialServer,
    ConnectionMode.local => Zh.createLocalRoom,
    ConnectionMode.remote => Zh.customServer,
  };

  String _profileSubtitle(ConnectionProfile profile) {
    final parts = <String>[
      if (profile.roomCode != null && profile.roomCode!.isNotEmpty)
        '${Zh.roomNumber} ${profile.roomCode}',
      if (profile.lastUsedAt != null) _relativeTime(profile.lastUsedAt!),
    ];
    return parts.join(' · ');
  }

  Future<void> _showProfileDetails(ConnectionProfile profile) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_profileLabel(profile)),
        content: SelectableText(
          '${_profileSubtitle(profile)}\n${profile.endpoint}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(Zh.close),
          ),
        ],
      ),
    );
  }

  String _relativeTime(DateTime at) {
    final delta = DateTime.now().toUtc().difference(at);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
    if (delta.inHours < 24) return '${delta.inHours} 小时前';
    return '${delta.inDays} 天前';
  }

  Widget _recentCard(ConnectionProfile profile) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: _busy ? null : () => _connectRecent(profile),
        leading: Icon(switch (profile.mode) {
          ConnectionMode.official => Icons.cloud_outlined,
          ConnectionMode.local => Icons.phone_iphone,
          ConnectionMode.remote => Icons.dns_outlined,
        }),
        title: Text(_profileLabel(profile)),
        subtitle: Text(
          _profileSubtitle(profile),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: Zh.profileDetails,
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showProfileDetails(profile),
            ),
            IconButton(
              tooltip: Zh.forgetProfile,
              icon: const Icon(Icons.close),
              onPressed: () => widget.state.forgetProfile(profile),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomNumberPanel(String code) {
    final textStyle = Theme.of(context).textTheme.displayLarge
        ?.copyWith(fontSize: 56, fontWeight: FontWeight.bold, letterSpacing: 6);
    return Semantics(
      button: true,
      label: Zh.copyRoomNumber,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _copyRoomCode(code),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              children: [
                Text(
                  Zh.roomNumber,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(code, style: textStyle),
                      ),
                    ),
                    IconButton(
                      tooltip: Zh.copyRoomNumber,
                      icon: const Icon(Icons.copy),
                      onPressed: () => _copyRoomCode(code),
                    ),
                  ],
                ),
                Text(
                  Zh.roomNumberTapToCopy,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _memberCard(int index) {
    final state = widget.state;
    final member = state.members[index];
    return Card(
      color: member.online
          ? null
          : Theme.of(context).disabledColor.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              member.report.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            Text(
              member.online ? '${member.report.bpm} BPM' : '-- BPM',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: member.online ? null : Theme.of(context).disabledColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (!member.online)
              Text(
                Zh.offline,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).disabledColor),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final roomCode = state.currentRoomCode;
    final connected = state.room.state == RoomConnectionState.connected;
    final recents = state.recentProfiles;
    final secondaryServer = AppConfig.effectiveSecondaryServer;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (roomCode != null) ...[
                _roomNumberPanel(roomCode),
                const SizedBox(height: 8),
              ],
              if (state.nickname == Zh.guestUser)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(Zh.guestNicknameHint),
                ),
              Text(
                '${Zh.connectionStatusLabel}：${Zh.roomState(state.room.state)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (state.roomMode == null && !connected)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(Zh.roomModeChoose),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _roomCode,
                decoration: InputDecoration(
                  labelText: Zh.roomNumber,
                  hintText: Zh.roomNumberHint,
                  helperText: Zh.roomCodeRuleHint,
                  errorText: _roomCodeLooksInvalid
                      ? Zh.roomError(
                          const RoomAddressException(
                            RoomAddressError.invalidRoomCode,
                          ),
                        )
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              // 二选一：官方服务器 / 本机房间。没有默认，必须点一下。
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _connectOfficial,
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text(Zh.connectOfficialServer),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _createLocalRoom,
                      icon: const Icon(Icons.phone_iphone),
                      label: const Text(Zh.createLocalRoom),
                    ),
                  ),
                ],
              ),
              if (state.roomMode == ConnectionMode.local)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    Zh.localRoomHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: connected ? state.disconnectRoom : null,
                    child: const Text(Zh.leaveRoom),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                Zh.recentConnections,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (recents.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(Zh.recentEmpty),
                )
              else
                ...recents.map(_recentCard),
              const SizedBox(height: 8),
              // 地址只在这里出现，且默认收起。
              ExpansionTile(
                title: const Text(Zh.manualAddressSection),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  TextField(
                    controller: _address,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: Zh.serverAddress,
                      hintText: Zh.serverAddressHint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: _busy ? null : _connectManual,
                        child: const Text(Zh.joinRoom),
                      ),
                      // 备用线路：只有注入了 SECONDARY_SERVER 才出现（不设默认）
                      if (secondaryServer != null)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _fillSecondary(secondaryServer),
                          child: const Text(Zh.useSecondaryServer),
                        ),
                    ],
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(Zh.developmentTransportWarning),
              ),
              Text(
                Zh.roomMembers,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (state.members.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(Zh.noRoomMembers),
                ),
            ]),
          ),
        ),
        if (state.members.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                childAspectRatio: 1.45,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _memberCard(index),
                childCount: state.members.length,
              ),
            ),
          ),
      ],
    );
  }
}
