/// Single source for identity and protocol defaults. Replace the application
/// ID in the native manifests too when the placeholder is retired.
abstract final class AppConfig {
  static const applicationId = 'com.wjmagit.heartrateshare';
  static const displayName = '共享心率';
  static const protocolVersion = 1;
  static const webSocketPath = '/ws';
  static const discoveryServiceType = '_heartrate._tcp';
  static const defaultWebSocketPort = 8765;
  static const defaultSecureWebSocketPort = 443;

  /// 官方服务器（运维最终确定，真机使用）：`wss://heart.mawj.asia:10086`。
  ///
  /// **必须保留 `wss://` 与显式 `:10086`**：10086 是非标准端口，任何地方把端口
  /// 丢掉或与默认 443 混用都会连到错误的服务上。
  ///
  /// 证书是 `*.mawj.asia` 通配，`heart.mawj.asia` 在其覆盖范围内；若真报证书错误，
  /// 说明域名/证书确实不匹配（或反代换了张证书），提示会指向"域名与证书不匹配"。
  ///
  /// 可用 `--dart-define=DEFAULT_SERVER=wss://heart.mawj.asia:10086` 覆盖；
  /// 裸主机名会被 `SecureEndpoint.parse` 纠正成 wss，显式 `ws://` 直接报错。
  static const officialServerHost = 'heart.mawj.asia';
  static const officialServerPort = 10086;
  static const officialServerSecure = true;

  /// 内置默认串（带 wss:// 与显式端口）。
  static const builtInOfficialServer = 'wss://heart.mawj.asia:10086';

  static const configuredServer = String.fromEnvironment(
    'DEFAULT_SERVER',
    defaultValue: '',
  );

  /// 官方服务器实际使用的端点：未注入就用内置默认。
  static String get effectiveOfficialServer {
    final value = configuredServer.trim();
    return value.isEmpty ? builtInOfficialServer : value;
  }

  /// 备用线路：**默认不配置**（不凭空给一个可能不存在的端点）。
  /// 需要时用 `--dart-define=SECONDARY_SERVER=wss://host:port` 注入，
  /// 房间页「高级」里的备用按钮只在配置后才出现。
  static const configuredSecondaryServer = String.fromEnvironment(
    'SECONDARY_SERVER',
    defaultValue: '',
  );

  static String? get effectiveSecondaryServer {
    final value = configuredSecondaryServer.trim();
    return value.isEmpty ? null : value;
  }

  static bool get hasSecondaryServer => effectiveSecondaryServer != null;

  /// 自签证书的可配置信任方式：钉住服务端证书的 SHA-256 指纹（十六进制，
  /// 大小写与冒号不敏感）。留空 = 走系统 CA 校验。
  ///
  /// 用法：flutter build apk --dart-define=CERT_SHA256=<指纹>
  /// 取指纹：openssl x509 -in server.crt -noout -fingerprint -sha256
  /// **不存在"全局跳过校验"的开关** —— 要么系统 CA，要么钉住一个明确指纹。
  static const pinnedCertificateSha256 = String.fromEnvironment(
    'CERT_SHA256',
    defaultValue: '',
  );

  /// 可由 CI 注入：--dart-define=DEFAULT_SERVER=hr.example.com
  /// 留空或保留占位值时，房间页不预填地址。
  static const defaultServerHost = String.fromEnvironment(
    'DEFAULT_SERVER',
    defaultValue: '',
  );

  static String get effectiveDefaultServerHost {
    final value = defaultServerHost.trim();
    if (value.isEmpty || value == 'YOUR_DEFAULT_SERVER') return '';
    return value;
  }

  static const reportInterval = Duration(seconds: 1);
  static const heartbeatInterval = Duration(seconds: 3);
  static const offlineAfter = Duration(seconds: 5);

  /// 用户点「连接」时的连接超时，允许慢设备慢慢建链。
  static const connectTimeout = Duration(seconds: 15);

  /// 自动重连单次尝试的超时：必须比 [offlineAfter] 同量级，
  /// 否则一次尝试就能把房间状态拖到离线。
  static const reconnectConnectTimeout = Duration(seconds: 6);

  static const removeMemberAfter = Duration(minutes: 2);
  static const maxMembers = 20;
  static const snapshotInterval = Duration(seconds: 1);
}
