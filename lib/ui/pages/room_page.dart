import 'package:flutter/material.dart';

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
  final _address = TextEditingController(text: 'localhost:8765');
  final _roomCode = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    _roomCode.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      await widget.state.room
          .connect(RoomAddress.parse(_address.text, roomCode: _roomCode.text));
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
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(Zh.roomError(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Text(
                  '${Zh.connectionStatusLabel}：${Zh.roomState(state.room.state)}'),
              const SizedBox(height: 8),
              TextField(
                  controller: _roomCode,
                  decoration: const InputDecoration(
                      labelText: Zh.roomShortCode,
                      hintText: Zh.roomShortCodeHint)),
              const SizedBox(height: 8),
              TextField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: Zh.relayAddress,
                  hintText: Zh.relayAddressHint,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton(
                    onPressed: _connect, child: const Text(Zh.joinRoom)),
                OutlinedButton(
                    onPressed: state.room.disconnect,
                    child: const Text(Zh.leaveRoom)),
                OutlinedButton(
                  onPressed: _toggleRelay,
                  child:
                      Text(state.relay == null ? Zh.hostRelay : Zh.stopRelay),
                ),
              ]),
              if (state.relay != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${Zh.roomShortCode}：${state.relay!.roomCode}\n'
                      '${Zh.localRoomAddress}：${state.relay!.address}'),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(Zh.developmentTransportWarning),
              ),
              Text(Zh.roomMembers,
                  style: Theme.of(context).textTheme.titleMedium),
              if (state.members.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(Zh.noRoomMembers),
                ),
            ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              childAspectRatio: 1.5,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
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
                        Text(member.report.displayName,
                            overflow: TextOverflow.ellipsis),
                        Text('${member.report.bpm} BPM',
                            style: Theme.of(context).textTheme.headlineMedium),
                        Text(member.online ? Zh.online : Zh.offline),
                        Text('seq ${member.report.sequence}'),
                      ],
                    ),
                  ),
                );
              },
              childCount: state.members.length,
            ),
          ),
        ),
      ],
    );
  }
}
