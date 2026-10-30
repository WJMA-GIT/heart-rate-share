import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';

/// 连接失败的**可分辨**原因。
///
/// 设计原则：`unclassified` 只是兜底，**不允许**成为常见真机故障的归宿。
/// 任何"TCP 通了但后面失败"的情况都必须落到下面某一项，并附带原始事实
/// （见 `RoomDiagnostics`）。真实故障分类：
///
/// - 证书类：`certificateUntrusted` / `certificateHostMismatch` / `certificatePinnedMismatch`
/// - 反代鉴权：`redirectedToLogin` / `unauthorized` / `forbidden`
/// - 反代上游不通：`badGateway` / `gatewayTimeout` / `serviceUnavailable`
/// - 协议/端口错配：`plaintextOnTlsPort` / `tlsAborted` / `tlsHandshake` / `handshakeRejected`
/// - 网络：`dnsFailure` / `connectionRefused` / `connectionTimeout` / `ipv6Unreachable`
/// - 请求本身：`badRequest` / `endpointNotFound`
enum RoomErrorCode {
  /// 系统 CA 校验不通过（自签、过期）。
  certificateUntrusted,

  /// 证书本身有效，但和访问的域名不匹配（通配证书不含根域时最常见：
  /// `*.mawj.asia` 不覆盖 `mawj.asia`）。
  certificateHostMismatch,

  /// 配了 CERT_SHA256，但服务端证书指纹对不上（换证书/中间人）。
  certificatePinnedMismatch,

  /// TLS 握手失败（协议版本/套件不匹配等）。
  tlsHandshake,

  /// 握手期间连接被对端关闭/重置：常见于反代不认识这个 SNI、
  /// 要求客户端证书，或 SNI 路由没配上。
  tlsAborted,

  /// 该端口说的是明文 HTTP，不是 TLS（TLS ClientHello 被当普通请求或直接被拒）。
  plaintextOnTlsPort,

  dnsFailure,
  connectionRefused,
  connectionTimeout,

  /// 解析出来的只有 IPv6 地址，而当前网络没有 IPv6 出口（ENETUNREACH /
  /// EAFNOSUPPORT）。家庭 NAS 只有 AAAA 记录时，这条是最常见的失败。
  ipv6Unreachable,

  /// 连上了但对方没按 WebSocket 升级（反向代理没配 upgrade 等）。
  handshakeRejected,

  /// 升级被重定向（3xx）：反代"要求登录"最常见，Location 会指向登录页。
  redirectedToLogin,

  /// 重定向到**同一个地址**，形成循环。通常是反代 Target 填成了自身域名，
  /// 或响应类型被配成"重定向"。拿到 Location 与循环本身就是 TLS 成功的证据。
  redirectLoop,

  /// 回探 HTTP 拿到 401：反代要求鉴权。
  unauthorized,

  /// 回探 HTTP 拿到 403：反代拒绝该来源/路径。
  forbidden,

  /// 回探 HTTP 拿到 502：反代连不上上游（Target 不通）。
  badGateway,

  /// 回探 HTTP 拿到 504：反代等上游超时。
  gatewayTimeout,

  /// 回探 HTTP 拿到 503：上游/网关暂时不可用。
  serviceUnavailable,

  /// 升级失败后回探到 HTTP 400：房间号/参数格式不对。
  badRequest,

  /// 升级失败后回探到 HTTP 404：路径或房间号不对。
  endpointNotFound,

  /// 兜底：确实没能归类。`RoomDiagnostics` 仍会给出原始异常与回探结果，
  /// 界面提示用户直接复制诊断信息给管理员。
  unclassified,
}

/// wss 的信任策略。
///
/// 默认（[none]）走系统 CA 校验 —— **不存在全局 accept-all 的开关**。
/// 运维若用自签证书，构建时用 `--dart-define=CERT_SHA256=<指纹>` 钉住一张
/// 明确的证书；指纹不匹配时直接失败，而不是"信任一切"。
final class RoomTls {
  const RoomTls({this.pinnedSha256 = ''});

  final String pinnedSha256;

  static const none = RoomTls();

  static RoomTls fromEnvironment() =>
      RoomTls(pinnedSha256: AppConfig.pinnedCertificateSha256);

  String get _normalizedPin =>
      pinnedSha256.toLowerCase().replaceAll(':', '').replaceAll(' ', '').trim();

  bool get hasPin => _normalizedPin.isNotEmpty;

  bool matchesCertificate(List<int> der) =>
      hasPin && sha256.convert(der).toString() == _normalizedPin;
}

/// 打开一条房间连接。ws 走默认实现；wss 在配了指纹时用自定义 HttpClient。
///
/// [onPinMismatch] 用于把"指纹不匹配"这个内部判定带给上层 —— HttpClient 的
/// 回调只能返回 bool，无法区分"我们钉的证书不对"和"系统 CA 不认"。
WebSocketChannel openRoomChannel(
  Uri uri, {
  RoomTls tls = RoomTls.none,
  void Function()? onPinMismatch,
}) {
  if (!tls.hasPin || uri.scheme != 'wss') {
    return WebSocketChannel.connect(uri);
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (certificate, host, port) {
      if (tls.matchesCertificate(certificate.der)) return true;
      onPinMismatch?.call();
      return false;
    };
  return IOWebSocketChannel.connect(uri, customClient: client);
}

/// 逐层剥开 `WebSocketChannelException` 包装，拿到真正的原因。
///
/// dart:io 的 WebSocket 客户端会把所有失败统一包成 `WebSocketChannelException`，
/// 光看外层什么都分不出来。实测（真机 + 本地复现）的 inner 才是判据：
///
/// | 现场 | 外层 | inner |
/// |---|---|---|
/// | wss 打到明文端口 | `WebSocketChannelException` | `HandshakeException: Connection terminated during handshake` |
/// | 302/307（跟随后被关） | `WebSocketChannelException` | `HttpException: Connection closed before full header…` |
/// | 重定向成环 | `WebSocketChannelException` | `RedirectException: Redirect loop detected` |
Object unwrapChannelError(Object error) {
  var current = error;
  for (var depth = 0; depth < 4; depth++) {
    final inner = current is WebSocketChannelException ? current.inner : null;
    if (inner == null || identical(inner, current)) break;
    current = inner;
  }
  return current;
}

/// 是否**收到过 HTTP 响应**（= TLS 已经握手成功）。
///
/// `HttpException` 只会在 HTTP 层真正开始解析时抛出；`RedirectException` /
/// `was not upgraded` 更是必须先有响应头。相反，单纯的 TLS 失败是
/// `HandshakeException` / `TlsException`，绝不会是这两类。
bool sawHttpResponse(Object error) {
  if (error is HttpException) return true;
  final text = '$error';
  return text.contains('Redirect') ||
      text.contains('was not upgraded') ||
      text.contains('status code');
}

/// 是否是 TLS **层**的失败（此时才可能谈"这个端口不是 TLS"）。
bool isTlsLayerError(Object error) {
  if (error is HandshakeException || error is TlsException) return true;
  final text = '$error';
  return text.contains('WRONG_VERSION_NUMBER') ||
      text.contains('first record does not look like a TLS handshake') ||
      text.contains('SSL routines') ||
      text.contains('no alternative certificate subject name');
}

/// 把底层异常归到 [RoomErrorCode]。纯函数，便于单测覆盖各分支。
///
/// 注意顺序：证书 → 反代响应（由调用方用 HTTP 回探结果覆盖）→ 网络 →
/// TLS/协议。最后才 `unclassified`。
RoomErrorCode classifyRoomError(Object error, {bool pinMismatch = false}) {
  if (pinMismatch) return RoomErrorCode.certificatePinnedMismatch;
  final text = '$error';
  final type = error.runtimeType.toString();

  // 0. 重定向循环：有 RedirectException 就说明已经收到过 HTTP 响应（TLS 已成功）
  if (text.contains('Redirect loop detected') ||
      text.contains('RedirectException')) {
    return RoomErrorCode.redirectLoop;
  }

  // 1. 证书
  if (text.contains('Hostname mismatch') ||
      text.contains('hostname mismatch') ||
      text.contains('certificate is not valid for') ||
      text.contains('IP address mismatch') ||
      text.contains('does not match any of the expected hostnames')) {
    return RoomErrorCode.certificateHostMismatch;
  }
  if (text.contains('CERTIFICATE_VERIFY_FAILED') ||
      text.contains('certificate is not trusted') ||
      text.contains('CERTIFICATE_UNKNOWN') ||
      text.contains('bad certificate') ||
      text.contains('unable to get local issuer') ||
      text.contains('self signed certificate')) {
    return RoomErrorCode.certificateUntrusted;
  }

  // 2. 网络
  if (text.contains('Failed host lookup') ||
      text.contains('nodename nor servname') ||
      text.contains('Name or service not known')) {
    return RoomErrorCode.dnsFailure;
  }
  if (text.contains('Network is unreachable') ||
      text.contains('Address family not supported') ||
      text.contains('Cannot assign requested address')) {
    return RoomErrorCode.ipv6Unreachable;
  }
  if (text.contains('Connection refused')) {
    return RoomErrorCode.connectionRefused;
  }
  if (text.contains('Connection timed out') ||
      text.contains('Connection timeout') ||
      text.contains('TimeoutException') ||
      text.contains('timed out')) {
    return RoomErrorCode.connectionTimeout;
  }

  // 3. 握手期被对端关闭/重置（TLS 层已开始，但没有正常 HandshakeException）
  if (text.contains('Connection reset by peer') ||
      text.contains('Connection terminated during handshake') ||
      text.contains('Broken pipe') ||
      text.contains('ECONNRESET') ||
      text.contains('EPIPE') ||
      type == 'ConnectionResetError') {
    return RoomErrorCode.tlsAborted;
  }

  // 4. 端口不是 TLS（明文响应里出现 HTTP 状态行）
  if (text.contains('Illegal request') ||
      text.contains('Invalid request') ||
      text.contains('WRONG_VERSION_NUMBER') ||
      text.contains('SSL routines') ||
      text.contains('first record does not look like a TLS handshake') ||
      text.contains('HTTP/1.')) {
    return RoomErrorCode.plaintextOnTlsPort;
  }

  // 5. TLS 握手/协议
  if (text.contains('HandshakeException') ||
      text.contains('TlsException') ||
      text.contains('TLS')) {
    return RoomErrorCode.tlsHandshake;
  }

  // 6. WebSocket 升级
  if (text.contains('was not upgraded to websocket') ||
      text.contains('WebSocketException')) {
    return RoomErrorCode.handshakeRejected;
  }

  // 7. Http 层（dart:io 在升级前解析响应失败时抛 HttpException）
  if (type == 'HttpException' || text.contains('HttpException')) {
    return RoomErrorCode.handshakeRejected;
  }

  return RoomErrorCode.unclassified;
}

/// 回探拿到的 HTTP 结果（升级失败后用来判断"到底是谁拦了"）。
///
/// 这些字段会原样进入可复制的诊断信息，不做二次加工。
final class HttpProbe {
  const HttpProbe({
    required this.scheme,
    required this.status,
    this.reasonPhrase = '',
    this.location = '',
    this.contentType = '',
    this.server = '',
    this.bodyPrefix = '',
    this.certSubject = '',
    this.certIssuer = '',
    this.redirects = const [],
    this.chain = const [],
    this.errorType = '',
    this.errorMessage = '',
  });

  /// 实际使用的 scheme（`https` 或 `http`；后者表示明文回探）。
  final String scheme;
  final int? status;
  final String reasonPhrase;
  final String location;
  final String contentType;
  final String server;
  final String bodyPrefix;
  final String certSubject;
  final String certIssuer;
  final List<String> redirects;

  /// 逐跳记录（`307 https://a/ws -> 307 https://a/ws`），用于证明循环。
  final List<String> chain;
  final String errorType;
  final String errorMessage;

  bool get ok => status != null;

  /// HTTP 状态 → 失败分类。回探成功时**优先于**异常文本分类。
  RoomErrorCode? get code {
    final value = status;
    if (value == null) return null;
    if (value >= 300 && value < 400) return RoomErrorCode.redirectedToLogin;
    return switch (value) {
      400 => RoomErrorCode.badRequest,
      401 => RoomErrorCode.unauthorized,
      403 => RoomErrorCode.forbidden,
      404 => RoomErrorCode.endpointNotFound,
      502 => RoomErrorCode.badGateway,
      503 => RoomErrorCode.serviceUnavailable,
      504 => RoomErrorCode.gatewayTimeout,
      _ => null,
    };
  }

  HttpProbe withChain(List<String> hops) => HttpProbe(
    scheme: scheme,
    status: status,
    reasonPhrase: reasonPhrase,
    location: location,
    contentType: contentType,
    server: server,
    bodyPrefix: bodyPrefix,
    certSubject: certSubject,
    certIssuer: certIssuer,
    redirects: redirects,
    chain: hops,
    errorType: errorType,
    errorMessage: errorMessage,
  );

  List<String> describe() => [
    if (ok)
      'http_probe=$scheme status=$status ${reasonPhrase.isEmpty ? '' : reasonPhrase}'
    else
      'http_probe=$scheme failed type=$errorType',
    if (location.isNotEmpty) 'http_location=$location',
    if (redirects.isNotEmpty) 'http_redirects=${redirects.join(' -> ')}',
    if (chain.isNotEmpty) 'http_redirect_chain=${chain.join(' -> ')}',
    if (contentType.isNotEmpty) 'http_content_type=$contentType',
    if (server.isNotEmpty) 'http_server=$server',
    if (bodyPrefix.isNotEmpty) 'http_body=${flatText(bodyPrefix)}',
    if (certSubject.isNotEmpty) 'tls_cert_subject=$certSubject',
    if (certIssuer.isNotEmpty) 'tls_cert_issuer=$certIssuer',
    if (!ok && errorMessage.isNotEmpty)
      'http_probe_error=$errorType: ${flatText(errorMessage)}',
  ];
}

/// 压成一行并截断，避免诊断信息被换行/长文本刷屏。
String flatText(String value, {int limit = 200}) {
  final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= limit ? flat : '${flat.substring(0, limit)}…';
}
