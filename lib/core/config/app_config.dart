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

  /// 官方服务器（运维最终确定）：`wss://relay.mawj.asia`，走 443、不显式带端口。
  ///
  /// 为什么是 `relay` 子域：家庭 NAS + 仅公网 IPv6，边界由 fn-knock 反代网关
  /// 终止 TLS；证书是 `*.mawj.asia` 通配，**不含根域**，所以必须用子域访问，
  /// 用 `mawj.asia` 会命中"证书与域名不匹配"。
  ///
  /// 可用 `--dart-define=DEFAULT_SERVER=wss://relay.mawj.asia` 覆盖；
  /// **必须带 wss:// 前缀**，裸主机名会被当成明文 ws（打到 443 必然失败），
  /// 所以解析走 `RoomAddress.parseSecure` 显式纠正。
  static const officialServerHost = 'relay.mawj.asia';
  static const officialServerPort = 443;
  static const officialServerSecure = true;

  static const configuredServer = String.fromEnvironment(
    'DEFAULT_SERVER',
    defaultValue: '',
  );

  /// 官方服务器实际使用的端点：未注入就用内置默认（带 wss://）。
  static String get effectiveOfficialServer {
    final value = configuredServer.trim();
    if (value.isEmpty) return 'wss://$officialServerHost';
    return value;
  }

  /// 备用端点：443 被运营商封时用。**不是默认值**，只在"高级"里手动切换。
  static const configuredSecondaryServer = String.fromEnvironment(
    'SECONDARY_SERVER',
    defaultValue: 'wss://relay.mawj.asia:8766',
  );

  static String get effectiveSecondaryServer {
    final value = configuredSecondaryServer.trim();
    return value.isEmpty
        ? 'wss://$officialServerHost:$secondaryServerPort'
        : value;
  }

  /// 备用端口（文档与测试用）。
  static const secondaryServerPort = 8766;

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
