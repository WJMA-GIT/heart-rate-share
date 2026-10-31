import 'dart:async';

import 'package:flutter/material.dart';

import '../../ble/ble_models.dart';
import '../../core/l10n/strings_zh.dart';
import '../app_state.dart';
import '../widgets/heart_rate_chart.dart';

final class HeartRatePage extends StatefulWidget {
  const HeartRatePage({required this.state, super.key});
  final AppState state;
  @override
  State<HeartRatePage> createState() => _HeartRatePageState();
}

final class _HeartRatePageState extends State<HeartRatePage> {
  /// 1 Hz 心跳：只为了让"数据断了"这件事自己浮出来（BPM 回到 --、曲线停住），
  /// 不生成任何数据点。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

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

  bool _isConnectedDevice(BleSnapshot ble, String id) =>
      ble.phase == BleConnectionPhase.subscribed && ble.connectedDeviceId == id;

  Future<void> _connect(String id) async {
    await _run(() => widget.state.heartRate.connect(id));
  }

  Future<void> _forget(String id) async {
    await _run(() => widget.state.heartRate.forget(id));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(Zh.deviceRemoved)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final ble = state.ble;
    final connected = ble.phase == BleConnectionPhase.subscribed;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _bpmHero(context, state),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _run(state.heartRate.scan),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text(Zh.scanDevices),
              ),
            ),
            if (connected) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _run(state.heartRate.disconnect),
                icon: const Icon(Icons.link_off),
                label: const Text(Zh.disconnect),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Text(
          Zh.heartRateDevices,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (ble.devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(Zh.noHeartRateDevices),
          )
        else
          ...ble.devices.map((device) => _deviceCard(context, ble, device)),
        if (ble.phase == BleConnectionPhase.error)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              ble.lastError == null
                  ? Zh.bleErrorTitle
                  : Zh.bleError(ble.lastError!),
            ),
          ),
        if (ble.phase == BleConnectionPhase.reconnectFailed)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(Zh.bleReconnectFailed),
          ),
      ],
    );
  }

  /// 大号 BPM + 真实采样折线。BPM 只在"最近还有采样"时显示，断流立刻回到 --。
  Widget _bpmHero(BuildContext context, AppState state) {
    final bpm = state.liveBpm;
    final active = state.ble.phase == BleConnectionPhase.subscribed;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.favorite,
                  size: 108,
                  color: Theme.of(context).colorScheme.error
                      .withValues(alpha: bpm == null ? 0.07 : 0.14),
                ),
                Text(
                  bpm == null ? '--' : '$bpm',
                  style: Theme.of(context).textTheme.displayLarge
                      ?.copyWith(fontSize: 72, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Text('BPM', style: Theme.of(context).textTheme.titleMedium),
            if (bpm == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  active ? Zh.waitingHeartRate : Zh.noChartData,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            HeartRateChart(series: state.series, bpm: bpm),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(
    BuildContext context,
    BleSnapshot ble,
    BleDeviceInfo device,
  ) {
    final isConnected = _isConnectedDevice(ble, device.id);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isConnected
            ? BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 1.5,
              )
            : BorderSide.none,
      ),
      child: ListTile(
        onTap: isConnected ? null : () => _connect(device.id),
        title: Text(
          device.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${Zh.rssiLabel} ${device.rssi} dBm · ${Zh.deviceIdLabel} ${device.id}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text(Zh.connectedDevice),
              )
            else
              FilledButton.tonal(
                onPressed: () => _connect(device.id),
                child: const Text(Zh.connectNow),
              ),
            PopupMenuButton<String>(
              tooltip: Zh.disconnect,
              onSelected: (value) {
                switch (value) {
                  case 'disconnect':
                    _run(widget.state.heartRate.disconnect);
                  case 'forget':
                    _forget(device.id);
                }
              },
              itemBuilder: (context) => [
                if (isConnected)
                  const PopupMenuItem(
                    value: 'disconnect',
                    child: Text(Zh.disconnect),
                  ),
                const PopupMenuItem(
                  value: 'forget',
                  child: Text(Zh.removeFromList),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
