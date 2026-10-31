import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
import '../../core/profile/connection_profile.dart';
import '../../room/room_address.dart';
import '../../room/room_client.dart';
import '../../room/room_code.dart';
import '../app_state.dart';
import '../widgets/connect_failure.dart';
import '../widgets/join_room_dialog.dart';
import '../widgets/room_code_card.dart';

final class RoomPage extends StatefulWidget {
  const RoomPage({required this.state, super.key});
  final AppState state;
  @override
  State<RoomPage> createState() => _RoomPageState();
}

final class _RoomPageState extends State<RoomPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8765');
  String _scheme = 'ws';
  bool _customTarget = false;
  bool _busy = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 页面上方选中的目标服：云端默认服，或用户自己填的自定义地址。
  ConnectionProfile _selectedTarget() {
    if (!_customTarget) return ConnectionProfile.official();
    final uri = RoomAddress.fromParts(
      scheme: _scheme,
      host: _host.text,
      port: _port.text,
    );
    return ConnectionProfile(
      mode: ConnectionMode.remote,
      host: uri.host,
      port: uri.port,
      secure: uri.scheme == 'wss',
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 创建房间：房间号由系统生成，服务端"加入即创建"。
  Future<void> _createRoom() async {
    final code = RoomCode.generate();
    await _run(() async {
      final target = _selectedTarget();
      await widget.state.connectProfile(target, roomCode: code);
    });
  }

  /// 加入房间：独立的目标输入对话框（粘贴或从最近连接选）。
  Future<void> _openJoinDialog({String? initialCode}) async {
    final request = await showDialog<JoinRequest>(
      context: context,
      builder: (dialogContext) => JoinRoomDialog(
        ownRoomCode: widget.state.currentRoomCode,
        recents: widget.state.recentProfiles,
        initialCode: initialCode,
      ),
    );
    if (request == null) return;
    await _run(() async {
      final target = request.profile ?? _selectedTarget();
      await widget.state.connectProfile(target, roomCode: request.code);
    });
  }

  /// 粘贴对方的房间号：**只在用户点按这一刻**读剪贴板，不在 build 里读，
  /// 也没有任何后台轮询。校验通过才进入确认加入。
  Future<void> _pasteRoomCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final code = RoomCode.normalize(data?.text);
    if (code == null) {
      _snack(Zh.roomCodeInvalid);
      return;
    }
    if (code == widget.state.currentRoomCode) {
      _snack(Zh.roomCodeIsOwn);
      return;
    }
    await _openJoinDialog(initialCode: code);
  }

  Future<void> _copyRoomCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    _snack(Zh.roomCodeCopied);
  }

  /// 最近连接：有房间号就直接重连，没有就进对话框补一个房间号。
  Future<void> _connectRecent(ConnectionProfile profile) async {
    final code = RoomCode.normalize(profile.roomCode);
    if (code == null) {
      _snack(Zh.roomCodeEmpty);
      return;
    }
    await _run(() => widget.state.connectProfile(profile, roomCode: code));
  }

  String _profileLabel(ConnectionProfile profile) => switch (profile.mode) {
    ConnectionMode.official => Zh.cloudRoom,
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

  String _relativeTime(DateTime at) {
    final delta = DateTime.now().toUtc().difference(at);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
    if (delta.inHours < 24) return '${delta.inHours} 小时前';
    return '${delta.inDays} 天前';
  }

  Widget _recentCard(ConnectionProfile profile) {
    // 字体比正文小一档，但不省略：长内容换行完整显示（跟随系统字号缩放）。
    final subtitleStyle = Theme.of(context).textTheme.bodySmall;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: _busy ? null : () => _connectRecent(profile),
        leading: Icon(switch (profile.mode) {
          ConnectionMode.official => Icons.cloud_outlined,
          ConnectionMode.remote => Icons.dns_outlined,
        }),
        title: Text(_profileLabel(profile), style: subtitleStyle),
        subtitle: Text(
          _profileSubtitle(profile),
          style: subtitleStyle,
          softWrap: true,
        ),
        trailing: IconButton(
          tooltip: Zh.forgetProfile,
          icon: const Icon(Icons.close),
          onPressed: () => widget.state.forgetProfile(profile),
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
              maxLines: 2,
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

  /// 自定义服务器：协议 + 地址 + 端口三段，不再让人手拼完整 URL。
  Widget _customServerFields() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: DropdownButtonFormField<String>(
              initialValue: _scheme,
              decoration: const InputDecoration(labelText: Zh.schemeLabel),
              items: const [
                DropdownMenuItem(value: 'ws', child: Text('ws')),
                DropdownMenuItem(value: 'wss', child: Text('wss')),
              ],
              onChanged: (value) => setState(() => _scheme = value ?? _scheme),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: Zh.hostLabel),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: Zh.portLabel),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final connected = state.room.state == RoomConnectionState.connected;
    final recents = state.recentProfiles;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              RoomCodeCard(
                roomCode: state.currentRoomCode,
                onCopy: _copyRoomCode,
                onPaste: _busy ? null : _pasteRoomCode,
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.cloud_outlined),
                    label: Text(Zh.targetCloud),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.dns_outlined),
                    label: Text(Zh.targetCustom),
                  ),
                ],
                selected: {_customTarget},
                onSelectionChanged: (value) =>
                    setState(() => _customTarget = value.first),
              ),
              if (_customTarget) _customServerFields(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _createRoom,
                      icon: const Icon(Icons.add),
                      label: const Text(Zh.createRoom),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _openJoinDialog(),
                      icon: const Icon(Icons.login),
                      label: const Text(Zh.joinRoom),
                    ),
                  ),
                ],
              ),
              if (connected) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: state.disconnectRoom,
                    child: const Text(Zh.leaveRoom),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '${Zh.connectionStatusLabel}：${Zh.roomState(state.room.state)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (Zh.relayError(state.room.lastServerError).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    Zh.relayError(state.room.lastServerError),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
              const SizedBox(height: 16),
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
