import 'package:flutter/material.dart';

import '../../ble/ble_models.dart';
import '../../core/l10n/strings_zh.dart';
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
            .showSnackBar(SnackBar(content: Text(Zh.bleError(error))));
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
        Text(
          sample == null ? '--' : '${sample.bpm}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.displayLarge
              ?.copyWith(fontSize: 96),
        ),
        Text(
          'BPM',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (sample == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(Zh.waitingHeartRate, textAlign: TextAlign.center),
          ),
        const SizedBox(height: 8),
        Text(
          '${Zh.connectionStatusLabel}：${Zh.blePhase(ble.phase)} · '
          '${Zh.adapterLabel}：${Zh.adapterState(ble.adapterState)}',
          textAlign: TextAlign.center,
        ),
        if (sample != null) ...[
          Text(
            '${Zh.sensorContactLabel}：${Zh.contact(sample.sensorContact)}',
            textAlign: TextAlign.center,
          ),
          Text(
            '${Zh.rrIntervalsLabel}：${sample.rrIntervalsMs.join(', ')} ms',
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => _run(state.heartRate.scan),
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text(Zh.scanDevices),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _selected,
          decoration: const InputDecoration(
            labelText: Zh.selectHeartRateDevice,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final device in ble.devices)
              DropdownMenuItem(
                value: device.id,
                child: Text(
                  '${device.name.isEmpty ? Zh.unnamedDevice : device.name} '
                  '(${device.rssi} dBm)',
                ),
              ),
          ],
          onChanged: (value) => setState(() => _selected = value),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _selected == null
              ? null
              : () => _run(() => state.heartRate.connect(_selected!)),
          icon: const Icon(Icons.link),
          label: const Text(Zh.connectHeartRateDevice),
        ),
        TextButton(
          onPressed: () => _run(state.heartRate.disconnect),
          child: const Text(Zh.disconnect),
        ),
        if (ble.phase == BleConnectionPhase.error)
          Text(
            ble.lastError == null
                ? Zh.bleErrorTitle
                : Zh.bleError(ble.lastError!),
          ),
        if (ble.phase == BleConnectionPhase.reconnectFailed)
          const Text(Zh.bleReconnectFailed),
      ],
    );
  }
}
