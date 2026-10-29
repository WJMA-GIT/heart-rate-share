import 'package:flutter/material.dart';

import '../../ble/ble_models.dart';
import '../../core/l10n/strings_zh.dart';
import '../../core/profile/connection_profile.dart';
import '../../room/room_client.dart';
import '../app_state.dart';
import '../widgets/heartbeat_ecg.dart';

final class HeartRatePage extends StatefulWidget {
  const HeartRatePage({
    required this.state,
    required this.onSwitchRoom,
    super.key,
  });
  final AppState state;

  /// 「官方服务器」那一行在未连接/需要选房间时切到房间页。
  final VoidCallback onSwitchRoom;
  @override
  State<HeartRatePage> createState() => _HeartRatePageState();
}

final class _HeartRatePageState extends State<HeartRatePage> {
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

  /// 主界面只露「官方服务器」这一行，地址本身不出现（地址在设置页）。
  Future<void> _officialAction() async {
    final state = widget.state;
    if (state.room.state == RoomConnectionState.connected) {
      widget.onSwitchRoom();
      return;
    }
    final recent = state.recentProfiles
        .where((profile) => profile.mode == ConnectionMode.official)
        .toList();
    final roomCode = recent.isEmpty ? null : recent.first.roomCode;
    if (roomCode == null || roomCode.isEmpty) {
      // 没有可复用的房间号，交给房间页选一条最近记录或新建。
      widget.onSwitchRoom();
      return;
    }
    await _run(() async {
      await state.connectProfile(
        ConnectionProfile.official(),
        roomCode: roomCode,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final sample = state.sample;
    final ble = state.ble;
    final connected = ble.phase == BleConnectionPhase.subscribed;
    final roomConnected = state.room.state == RoomConnectionState.connected;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _bpmHero(context, sample?.bpm, connected),
        _officialServerRow(context, roomConnected),
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
          ...ble.devices.map(
            (device) => _deviceCard(context, ble, device, roomConnected),
          ),
        const SizedBox(height: 12),
        Text(
          '${Zh.connectionStatusLabel}：${Zh.blePhase(ble.phase)} · '
          '${Zh.adapterLabel}：${Zh.adapterState(ble.adapterState)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (sample != null) ...[
          Text(
            '${Zh.sensorContactLabel}：${Zh.contact(sample.sensorContact)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            '${Zh.rrIntervalsLabel}：${sample.rrIntervalsMs.join(', ')} ms',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
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

  Widget _bpmHero(BuildContext context, int? bpm, bool connected) {
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
                      .withValues(alpha: connected ? 0.14 : 0.07),
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
                  Zh.waitingHeartRate,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            HeartbeatEcg(bpm: bpm, active: connected),
          ],
        ),
      ),
    );
  }

  Widget _officialServerRow(BuildContext context, bool roomConnected) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.cloud_outlined),
        title: const Text(Zh.officialServer),
        subtitle: Text(
          roomConnected ? Zh.roomState(RoomConnectionState.connected) : '',
        ),
        trailing: FilledButton.tonal(
          onPressed: _officialAction,
          child: Text(
            roomConnected ? Zh.officialServerSwitch : Zh.officialServerConnect,
          ),
        ),
      ),
    );
  }

  Widget _deviceCard(
    BuildContext context,
    BleSnapshot ble,
    BleDeviceInfo device,
    bool roomConnected,
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
