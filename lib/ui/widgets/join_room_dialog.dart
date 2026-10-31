import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
import '../../core/profile/connection_profile.dart';
import '../../room/room_code.dart';

/// 「加入房间」的目标：房间号 + 可选的服务器配置。
///
/// [profile] 为 null 表示用页面上方当前选中的目标（云端默认服 / 自定义）。
final class JoinRequest {
  const JoinRequest({required this.code, this.profile});

  final String code;
  final ConnectionProfile? profile;
}

/// 加入房间的**独立目标输入对话框**。
///
/// 自己的房间号只出现在只读卡片里，这里只输别人的：可以粘贴、可以从最近连接
/// 挑一条。剪贴板只在用户点「从剪贴板粘贴」时读一次——build 里从不读取，也没有
/// 任何后台轮询；房间号沿用 `^[A-Za-z0-9_-]{1,64}$` 校验，不合法就地报错。
final class JoinRoomDialog extends StatefulWidget {
  const JoinRoomDialog({
    required this.ownRoomCode,
    required this.recents,
    this.initialCode,
    super.key,
  });

  /// 自己的房间号：粘进来会明确拒绝，避免"把自己的号当加入目标"。
  final String? ownRoomCode;
  final List<ConnectionProfile> recents;
  final String? initialCode;

  @override
  State<JoinRoomDialog> createState() => _JoinRoomDialogState();
}

final class _JoinRoomDialogState extends State<JoinRoomDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialCode ?? '',
  );
  ConnectionProfile? _profile;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final raw = data?.text ?? '';
    final code = RoomCode.normalize(raw);
    setState(() {
      if (code == null) {
        _error = raw.trim().isEmpty ? Zh.roomCodeEmpty : Zh.roomCodeInvalid;
        return;
      }
      _controller.text = code;
      _error = null;
    });
  }

  void _submit() {
    final code = RoomCode.normalize(_controller.text);
    if (code == null) {
      setState(() => _error = Zh.roomCodeInvalid);
      return;
    }
    if (widget.ownRoomCode != null && code == widget.ownRoomCode) {
      setState(() => _error = Zh.roomCodeIsOwn);
      return;
    }
    Navigator.of(context).pop(JoinRequest(code: code, profile: _profile));
  }

  void _selectRecent(ConnectionProfile profile) {
    setState(() {
      _profile = profile;
      final code = RoomCode.normalize(profile.roomCode);
      if (code != null) _controller.text = code;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text(Zh.joinRoom),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                LengthLimitingTextInputFormatter(RoomCode.maxLength),
              ],
              decoration: InputDecoration(
                labelText: Zh.roomNumber,
                hintText: Zh.roomNumberHint,
                helperText: Zh.joinRoomCodeHelp,
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste),
                label: const Text(Zh.pasteFromClipboard),
              ),
            ),
            if (widget.recents.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(Zh.joinFromRecent, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final profile in widget.recents)
                    ChoiceChip(
                      label: Text(_recentLabel(profile)),
                      selected: _profile?.id == profile.id,
                      onSelected: (_) => _selectRecent(profile),
                    ),
                ],
              ),
            ],
            if (_profile != null) ...[
              const SizedBox(height: 8),
              Text(
                Zh.joinTargetServer(_profile!.endpoint),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(Zh.cancel),
        ),
        FilledButton(onPressed: _submit, child: const Text(Zh.joinRoom)),
      ],
    );
  }

  String _recentLabel(ConnectionProfile profile) {
    final label = switch (profile.mode) {
      ConnectionMode.official => Zh.cloudRoom,
      ConnectionMode.remote => Zh.customServer,
    };
    final code = profile.roomCode;
    return code == null || code.isEmpty ? label : '$label $code';
  }
}
