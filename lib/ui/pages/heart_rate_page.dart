import 'package:flutter/material.dart';

import '../../ble/ble_models.dart';
import '../app_state.dart';

final class HeartRatePage extends StatefulWidget {
  const HeartRatePage({required this.state, super.key});
  final AppState state;
  @override
  State<HeartRatePage> createState() => _HeartRatePageState();
}

final class _HeartRatePageState extends State<HeartRatePage> {
  String? _selected;
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final sample = state.sample;
    final ble = state.ble;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(sample == null ? '--' : '${sample.bpm}',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .displayLarge
                ?.copyWith(fontSize: 96)),
        Text('BPM',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Status: ${ble.phase.name} · Adapter: ${ble.adapterState}',
            textAlign: TextAlign.center),
        if (sample != null) ...[
          Text('Contact: ${sample.sensorContact ?? 'not supported'}',
              textAlign: TextAlign.center),
          Text('RR: ${sample.rrIntervalsMs.join(', ')} ms',
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => _run(state.heartRate.scan),
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Scan HRS devices'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _selected,
          decoration: const InputDecoration(
              labelText: 'Heart-rate strap', border: OutlineInputBorder()),
          items: [
            for (final device in ble.devices)
              DropdownMenuItem(
                  value: device.id,
                  child: Text('${device.displayName} (${device.rssi} dBm)')),
          ],
          onChanged: (value) => setState(() => _selected = value),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _selected == null
              ? null
              : () => _run(() => state.heartRate.connect(_selected!)),
          icon: const Icon(Icons.link),
          label: const Text('Connect'),
        ),
        TextButton(
            onPressed: () => _run(state.heartRate.disconnect),
            child: const Text('Disconnect')),
        if (ble.phase == BleConnectionPhase.error)
          Text(ble.lastError ?? 'Unknown BLE error'),
      ],
    );
  }
}
