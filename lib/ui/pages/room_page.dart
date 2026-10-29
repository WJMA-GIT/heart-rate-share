import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/l10n/strings_zh.dart';
import '../../room/room_address.dart';
import '../app_state.dart';

final class RoomPage extends StatefulWidget {
  const RoomPage({required this.state, super.key});
  final AppState state;
  @override
  State<RoomPage> createState() => _RoomPageState();
}

final class _RoomPageState extends State<RoomPage> {
  late final TextEditingController _address;
  final _roomCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
      text: AppConfig.effectiveDefaultServerHost,
    );
  }

  @override
  void dispose() {
    _address.dispose();
    _roomCode.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_roomCode.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(Zh.roomNumberRequired)));
      return;
    }
    try {
      await widget.state.room.connect(
        RoomAddress.parse(_address.text, roomCode: _roomCode.text),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(Zh.roomError(error))));
      }
    }
  }

  Future<void> _toggleRelay() async {
    try {
      await (widget.state.relay == null
          ? widget.state.startRelay()
          : widget.state.stopRelay());
      final relay = widget.state.relay;
      if (mounted && relay != null) {
        _roomCode.text = relay.roomCode;
        _address.text = '127.0.0.1:${relay.port}';
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(Zh.roomError(error))));
      }
    }
  }

  Future<void> _copyRoomCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(Zh.roomCodeCopied)));
  }

  Widget _roomNumberPanel(String? code) {
    if (code == null || code.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Text(
            Zh.roomNotJoined,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }

    final textStyle = Theme.of(context).textTheme.displayLarge
        ?.copyWith(fontSize: 64, fontWeight: FontWeight.bold, letterSpacing: 8);
    return Semantics(
      button: true,
      label: Zh.copyRoomNumber,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _copyRoomCode(code),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Column(
              children: [
                Text(
                  Zh.roomNumber,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
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
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _roomNumberPanel(roomCode),
              if (state.nickname == Zh.guestUser)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(Zh.guestNicknameHint),
                ),
              const SizedBox(height: 8),
              Text(
                '${Zh.connectionStatusLabel}：${Zh.roomState(state.room.state)}',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _roomCode,
                decoration: const InputDecoration(
                  labelText: Zh.roomNumber,
                  hintText: Zh.roomNumberHint,
                ),
              ),
              const SizedBox(height: 8),
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
                  FilledButton(
                    onPressed: _connect,
                    child: const Text(Zh.joinRoom),
                  ),
                  OutlinedButton(
                    onPressed: state.room.disconnect,
                    child: const Text(Zh.leaveRoom),
                  ),
                  OutlinedButton(
                    onPressed: _toggleRelay,
                    child: Text(
                      state.relay == null ? Zh.hostRelay : Zh.stopRelay,
                    ),
                  ),
                ],
              ),
              if (state.relay != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${Zh.localRoomAddress}：${state.relay!.address}'),
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
