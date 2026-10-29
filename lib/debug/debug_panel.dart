import 'package:flutter/material.dart';

import '../core/l10n/strings_zh.dart';
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
        Text('${Zh.bleAdapterDebug}: ${Zh.adapterState(ble.adapterState)}'),
        Text('${Zh.connectionStateDebug}: ${Zh.blePhase(ble.phase)}'),
        Text('${Zh.connectedDeviceDebug}: ${ble.connectedDeviceId ?? '-'}'),
        Text('${Zh.rawHrsDebug}: ${hexBytes(ble.lastRawBytes)}'),
        Text(
            'BPM: ${sample?.bpm ?? '-'} · RR: ${sample?.rrIntervalsMs ?? const []}'),
        const Divider(),
        Text(Zh.discoveredDevices,
            style: Theme.of(context).textTheme.titleMedium),
        if (ble.devices.isEmpty) const Text(Zh.waitingHeartRate),
        for (final device in ble.devices)
          Text('${device.name.isEmpty ? Zh.unnamedDevice : device.name}\n'
              'ID=${device.id} RSSI=${device.rssi} dBm'),
        const Divider(),
        Text(Zh.roomMembers, style: Theme.of(context).textTheme.titleMedium),
        if (state.members.isEmpty) const Text(Zh.noRoomMembers),
        for (final member in state.members)
          Text('${member.report.memberId} ${member.report.displayName}: '
              '${member.report.bpm} online=${member.online} seq=${member.report.sequence}'),
        const Divider(),
        Text(Zh.recentDiagnostics,
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
