import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';

/// 连接失败的**可分辨**原因。证书类错误必须能和"网断了"分开，
/// 否则运维排查时分不清是证书没配好还是服务没起。
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

  dnsFailure,
  connectionRefused,
  connectionTimeout,

  /// 解析出来的只有 IPv6 地址，而当前网络没有 IPv6 出口（ENETUNREACH /
  /// EAFNOSUPPORT）。家庭 NAS 只有 AAAA 记录时，这条是最常见的失败。
  ipv6Unreachable,

  /// 连上了但对方没按 WebSocket 升级（反向代理没配 upgrade 等）。
  handshakeRejected,

  /// 升级失败后回探到 HTTP 400：房间号/参数格式不对。
  badRequest,

  /// 升级失败后回探到 HTTP 404：路径或房间号不对。
  endpointNotFound,
  unknown,
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

/// 把底层异常归到 [RoomErrorCode]。纯函数，便于单测覆盖证书/网络分支。
RoomErrorCode classifyRoomError(Object error, {bool pinMismatch = false}) {
  if (pinMismatch) return RoomErrorCode.certificatePinnedMismatch;
  final text = '$error';
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
      text.contains('bad certificate')) {
    return RoomErrorCode.certificateUntrusted;
  }
  if (text.contains('Failed host lookup') ||
      text.contains('nodename nor servname') ||
      text.contains('Name or service not known')) {
    return RoomErrorCode.dnsFailure;
  }
  if (text.contains('Connection refused')) {
    return RoomErrorCode.connectionRefused;
  }
  if (text.contains('Network is unreachable') ||
      text.contains('Address family not supported') ||
      text.contains('Cannot assign requested address')) {
    return RoomErrorCode.ipv6Unreachable;
  }
  if (text.contains('Connection timed out') ||
      text.contains('Connection timeout') ||
      text.contains('TimeoutException') ||
      text.contains('timed out')) {
    return RoomErrorCode.connectionTimeout;
  }
  if (text.contains('HandshakeException') ||
      text.contains('TlsException') ||
      text.contains('WRONG_VERSION_NUMBER') ||
      text.contains('TLS')) {
    return RoomErrorCode.tlsHandshake;
  }
  if (text.contains('was not upgraded to websocket') ||
      text.contains('WebSocketException')) {
    return RoomErrorCode.handshakeRejected;
  }
  return RoomErrorCode.unknown;
}
