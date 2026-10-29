import 'package:flutter/material.dart';

import '../../room/room_address.dart';
import '../../room/room_client.dart';
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
      await widget.state.room.connect(RoomAddress.parse(_address.text, roomCode: _roomCode.text));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
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
              Text('Connection: ${state.room.state.name}'),
              const SizedBox(height: 8),
              TextField(controller: _roomCode, decoration: const InputDecoration(labelText: 'Room short code')),
              const SizedBox(height: 8),
              TextField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'Relay address (fallback)',
                  hintText: '192.168.1.10:8765 or ws://host:8765',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton(onPressed: _connect, child: const Text('Join room')),
                OutlinedButton(onPressed: state.room.disconnect, child: const Text('Leave')),
                OutlinedButton(
                  onPressed: state.relay == null ? state.startRelay : state.stopRelay,
                  child: Text(state.relay == null ? 'Host relay (dev)' : 'Stop relay'),
                ),
              ]),
              if (state.relay != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Room ${state.relay!.roomCode}\n${state.relay!.address}'),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Development transport is ws://; do not use sensitive data on untrusted LANs.'),
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
                  color: member.online ? null : Theme.of(context).disabledColor.withOpacity(0.15),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(member.report.displayName, overflow: TextOverflow.ellipsis),
                        Text('${member.report.bpm} BPM', style: Theme.of(context).textTheme.headlineMedium),
                        Text(member.online ? 'online' : 'offline'),
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
