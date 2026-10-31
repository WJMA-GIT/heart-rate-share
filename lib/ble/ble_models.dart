enum BleConnectionPhase {
  idle,
  adapterOff,
  permissionDenied,
  scanning,
  connecting,
  discovering,
  subscribed,
  disconnecting,

  /// 链路非用户主动断开，正在按退避策略自动重连。
  reconnecting,

  /// 自动重连配额用尽，需要用户手动重连。
  reconnectFailed,
  error,
}

final class BleDeviceInfo {
  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.rssi,
    this.isHrsCandidate = false,
  });
  final String id; // Android MAC; iOS UUID (not a MAC address).
  final String name;
  final int rssi;

  /// 广播里是否带 0x180D（心率服务）。Windows 全量扫描时用来排序：
  /// 心率带排前面，但不是过滤条件（很多设备只在连接后才暴露服务）。
  final bool isHrsCandidate;
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
