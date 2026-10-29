/// Single source for identity and protocol defaults. Replace the application
/// ID in the native manifests too when the placeholder is retired.
abstract final class AppConfig {
  static const applicationId = 'com.wjmagit.heartrateshare';
  static const displayName = '共享心率';
  static const protocolVersion = 1;
  static const webSocketPath = '/ws';
  static const discoveryServiceType = '_heartrate._tcp';
  static const defaultWebSocketPort = 8765;
  static const reportInterval = Duration(seconds: 1);
  static const heartbeatInterval = Duration(seconds: 3);
  static const offlineAfter = Duration(seconds: 5);
  static const removeMemberAfter = Duration(minutes: 2);
  static const maxMembers = 20;
  static const snapshotInterval = Duration(seconds: 1);
}
