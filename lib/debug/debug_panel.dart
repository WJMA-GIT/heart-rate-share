import 'package:flutter/material.dart';

import '../core/logging/app_logger.dart';
import '../ui/app_state.dart';
import '../ui/widgets.dart';

final class DebugPanel extends StatelessWidget {
  const DebugPanel({required this.state, super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ble = state.ble;
    final sample = state.sample;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('BLE adapter: ${ble.adapterState}'),
        Text('Connection state: ${ble.phase.name}'),
        Text('Connected device: ${ble.connectedDeviceId ?? '-'}'),
        Text('Raw HRS: ${hexBytes(ble.lastRawBytes)}'),
        Text(
            'BPM: ${sample?.bpm ?? '-'} · RR: ${sample?.rrIntervalsMs ?? const []}'),
        const Divider(),
        Text('Discovered devices',
            style: Theme.of(context).textTheme.titleMedium),
        for (final device in ble.devices)
          Text(
              '${device.displayName}\nID=${device.id} RSSI=${device.rssi} dBm'),
        const Divider(),
        Text('Room members', style: Theme.of(context).textTheme.titleMedium),
        for (final member in state.members)
          Text('${member.report.memberId} ${member.report.displayName}: '
              '${member.report.bpm} online=${member.online} seq=${member.report.sequence}'),
        const Divider(),
        Text('Recent diagnostics',
            style: Theme.of(context).textTheme.titleMedium),
        for (final entry in state.debug.entries.reversed.take(100))
          SelectableText(
            entry.format(),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: entry.level == LogLevel.error
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
      ],
    );
  }
}
