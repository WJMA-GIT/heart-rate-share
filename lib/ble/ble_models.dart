enum BleConnectionPhase {
  idle,
  adapterOff,
  permissionDenied,
  scanning,
  connecting,
  discovering,
  subscribed,
  disconnecting,
  error,
}

final class BleDeviceInfo {
  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id; // Android MAC; iOS UUID (not a MAC address).
  final String name;
  final int rssi;
  String get displayName => name.isEmpty ? '(unnamed HRS device)' : name;
}

final class BleSnapshot {
  const BleSnapshot({
    this.adapterState = 'unknown',
    this.phase = BleConnectionPhase.idle,
    this.devices = const [],
    this.connectedDeviceId,
    this.lastError,
    this.lastRawBytes = const [],
  });
  final String adapterState;
  final BleConnectionPhase phase;
  final List<BleDeviceInfo> devices;
  final String? connectedDeviceId;
  final String? lastError;
  final List<int> lastRawBytes;

  BleSnapshot copyWith({
    String? adapterState,
    BleConnectionPhase? phase,
    List<BleDeviceInfo>? devices,
    String? connectedDeviceId,
    String? lastError,
    List<int>? lastRawBytes,
    bool clearError = false,
  }) => BleSnapshot(
    adapterState: adapterState ?? this.adapterState,
    phase: phase ?? this.phase,
    devices: devices ?? this.devices,
    connectedDeviceId: connectedDeviceId ?? this.connectedDeviceId,
    lastError: clearError ? null : lastError ?? this.lastError,
    lastRawBytes: lastRawBytes ?? this.lastRawBytes,
  );
}
