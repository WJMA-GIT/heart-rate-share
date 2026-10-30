import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';
import 'room_transport.dart';

/// 单次"连某个地址"的尝试记录，用来拼可复制的诊断信息。
final class RoomAttempt {
  const RoomAttempt({
    required this.address,
    required this.family,
    required this.elapsed,
    this.errorName,
    this.errorType,
    this.errorCode,
  });

  final String address;

  /// `IPv6` / `IPv4`
  final String family;
  final Duration elapsed;
  final String? errorName;

  /// 原始异常类型（`SocketException` / `HandshakeException` / …）。
  final String? errorType;
  final RoomErrorCode? errorCode;

  bool get ok => errorName == null;

  String describe() => ok
      ? '$family $address ok ${elapsed.inMilliseconds}ms'
      : '$family $address ${errorCode?.name ?? 'unclassified'} '
            'type=${errorType ?? '?'} '
            '"${(errorName ?? '').replaceAll(RegExp(r'\s+'), ' ')}" '
            '${elapsed.inMilliseconds}ms';
}

/// 一次连接尝试的完整现场：解析出了哪些地址、每个地址怎么失败的。
///
/// 用途就是需求里那句"失败时要能给出可复制的诊断信息"——
/// 上一轮现场把 `Failed host lookup` 当成断连原因追偏了，所以这里把
/// **地址家族、逐地址结果、最终归类**都留成文本。
final class RoomDiagnostics {
  const RoomDiagnostics({
    required this.scheme,
    required this.host,
    required this.port,
    required this.resolved,
    required this.attempts,
    required this.code,
    this.errorType = '',
    this.errorMessage = '',
    this.probe,
    this.tcpReached = false,
  });

  final String scheme;
  final String host;
  final int port;
  final List<String> resolved;
  final List<RoomAttempt> attempts;
  final RoomErrorCode code;

  /// 最终异常的原始类型与消息（不加工，方便直接贴给管理员）。
  final String errorType;
  final String errorMessage;

  /// 升级失败后回探到的 HTTP 事实（状态码 / Location / 证书 / 明文回探）。
  final HttpProbe? probe;

  /// TCP 是否至少有一条连通（用来把"网络不通"和"TLS 之后失败"分开）。
  final bool tcpReached;

  /// IPv6 字面量要加方括号，否则拼出来的 URL 是错的。
  String get endpoint {
    final literal = host.contains(':') ? '[$host]' : host;
    return '$scheme://$literal:$port';
  }

  /// 可复制的诊断文本：**先给原始事实，再给分类**，避免只剩一个标签。
  String toClipboardText() {
    final buffer = StringBuffer()
      ..writeln('endpoint=$endpoint')
      ..writeln('result=${code.name}')
      ..writeln('tcp_reached=${tcpReached ? 'yes' : 'no'}')
      ..writeln(
        'resolved=${resolved.isEmpty ? '(none)' : resolved.join(', ')}',
      );
    for (final attempt in attempts) {
      buffer.writeln('attempt=${attempt.describe()}');
    }
    if (errorType.isNotEmpty || errorMessage.isNotEmpty) {
      buffer.writeln('error_type=${errorType.isEmpty ? '?' : errorType}');
      buffer.writeln('error_message=${flatText(errorMessage, limit: 400)}');
    }
    final probeResult = probe;
    if (probeResult != null) {
      for (final line in probeResult.describe()) {
        buffer.writeln(line);
      }
    }
    return buffer.toString().trimRight();
  }
}

final class RoomOpenResult {
  const RoomOpenResult({required this.channel, required this.diagnostics});
  final WebSocketChannel channel;
  final RoomDiagnostics diagnostics;
}

final class RoomOpenException implements Exception {
  const RoomOpenException(this.code, this.diagnostics);
  final RoomErrorCode code;
  final RoomDiagnostics diagnostics;

  @override
  String toString() => 'RoomOpenException(${code.name}): $endpoint';

  String get endpoint => diagnostics.endpoint;
}

/// 依次尝试每个地址，第一个成功即返回；每个地址单独限时，避免"首选卡住"。
///
/// 抽成泛型函数是为了能单测「首选失败 → 快速换下一个」这条路径，
/// 不需要真的开网络。
Future<T> connectFirstAvailable<T>({
  required List<InternetAddress> addresses,
  required Future<T> Function(InternetAddress address) connect,
  required void Function(RoomAttempt attempt) record,
  Duration perAddress = const Duration(seconds: 4),
}) async {
  Object? lastError;
  StackTrace? lastStack;
  for (final address in addresses) {
    final watch = Stopwatch()..start();
    try {
      final result = await connect(address).timeout(perAddress);
      record(
        RoomAttempt(
          address: address.address,
          family: address.type.name,
          elapsed: watch.elapsed,
        ),
      );
      return result;
    } on Object catch (error, stack) {
      lastError = error;
      lastStack = stack;
      record(
        RoomAttempt(
          address: address.address,
          family: address.type.name,
          elapsed: watch.elapsed,
          errorName: '$error',
          errorType: error.runtimeType.toString(),
          errorCode: classifyRoomError(error),
        ),
      );
    }
  }
  Error.throwWithStackTrace(
    lastError ?? StateError('no address to connect'),
    lastStack ?? StackTrace.current,
  );
}

/// 解析主机名：字面量地址直接用，域名走 `lookup` 拿全部 A/AAAA。
///
/// 不写死 IPv4：`lookup` 返回什么就尝试什么（家庭 NAS 只有 AAAA 是正常情况）。
Future<List<InternetAddress>> resolveHost(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return [literal];
  return InternetAddress.lookup(host);
}

/// 打开一条房间连接：**自己解析、逐地址尝试、保留原主机名做 TLS 校验**。
///
/// 关键点：`HttpClient.connectionFactory` 允许我们自己建 socket，而请求 URI
/// 仍然是最初的域名 —— 所以 wss 的 SNI 与证书校验依旧针对 `mawj.asia`，
/// 不会因为"先连 IP"就变成对 IP 校验。
Future<RoomOpenResult> openRoomChannelResolved(
  Uri uri, {
  RoomTls tls = RoomTls.none,
  Duration perAddress = const Duration(seconds: 4),
  void Function()? onPinMismatch,
}) async {
  final attempts = <RoomAttempt>[];
  final resolved = <String>[];
  final port = uri.hasPort
      ? uri.port
      : (uri.scheme == 'wss'
            ? AppConfig.defaultSecureWebSocketPort
            : AppConfig.defaultWebSocketPort);

  List<InternetAddress> addresses;
  try {
    addresses = await resolveHost(uri.host);
  } on SocketException catch (error) {
    final code = classifyRoomError(error);
    throw RoomOpenException(
      code,
      RoomDiagnostics(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        resolved: const [],
        attempts: const [],
        code: code,
      ),
    );
  }
  for (final address in addresses) {
    resolved.add('${address.type.name} ${address.address}');
  }
  if (addresses.isEmpty) {
    const code = RoomErrorCode.dnsFailure;
    throw RoomOpenException(
      code,
      RoomDiagnostics(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        resolved: const [],
        attempts: const [],
        code: code,
      ),
    );
  }

  var pinMismatch = false;
  final client = HttpClient()
    ..connectionTimeout = perAddress
    ..idleTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (certificate, host, certificatePort) {
      if (!tls.hasPin) return false; // 交给系统 CA 校验，绝不 accept-all
      if (tls.matchesCertificate(certificate.der)) return true;
      pinMismatch = true;
      onPinMismatch?.call();
      return false;
    }
    ..connectionFactory = (url, proxyHost, proxyPort) {
      return Future.value(
        ConnectionTask.fromSocket(
          connectFirstAvailable<Socket>(
            addresses: addresses,
            perAddress: perAddress,
            record: attempts.add,
            connect: (address) =>
                Socket.connect(address, port, timeout: perAddress),
          ),
          () {},
        ),
      );
    };

  try {
    final channel = IOWebSocketChannel.connect(uri, customClient: client);
    await channel.ready;
    return RoomOpenResult(
      channel: channel,
      diagnostics: RoomDiagnostics(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        resolved: resolved,
        attempts: attempts,
        code: RoomErrorCode.unclassified,
      ),
    );
  } on Object catch (error) {
    final tcpReached = attempts.any((attempt) => attempt.ok);
    // 只要 TCP 通过，就一定回探：升级失败后真正的拦截点几乎总是 HTTP 层
    // （302 登录页 / 401 / 403 / 502 / 504），没有回探就只能给出「未知」。
    final probeResult = tcpReached
        ? await _probeHttp(uri, port, perAddress, triedTls: uri.scheme == 'wss')
        : null;
    final code = _finalCode(
      error,
      attempts,
      pinMismatch: pinMismatch,
      probe: probeResult,
      attemptedTls: uri.scheme == 'wss',
    );
    throw RoomOpenException(
      code,
      RoomDiagnostics(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        resolved: resolved,
        attempts: attempts,
        code: code,
        errorType: error.runtimeType.toString(),
        errorMessage: '$error',
        probe: probeResult,
        tcpReached: tcpReached,
      ),
    );
  } finally {
    // 连接池用完即弃：房间连接只需要一条长连接。
    client.close(force: false);
  }
}

/// 归类最终失败：**回探到的事实优先**，其次异常文本，最后才是兜底。
///
/// 顺序很重要：真机上 "TCP 通、TLS/升级失败" 的绝大多数是反代返回了 3xx/401/403/
/// 502/504，而这些在异常文本里是看不到的。
RoomErrorCode _finalCode(
  Object error,
  List<RoomAttempt> attempts, {
  required bool pinMismatch,
  HttpProbe? probe,
  bool attemptedTls = false,
}) {
  if (pinMismatch) return RoomErrorCode.certificatePinnedMismatch;
  // wss 目标、TLS 失败，但同一端口的**明文** HTTP 有响应 → 这个端口不是 TLS。
  if (attemptedTls && probe != null && probe.scheme == 'http' && probe.ok) {
    return RoomErrorCode.plaintextOnTlsPort;
  }
  final fromProbe = probe?.code;
  if (fromProbe != null) return fromProbe;

  final base = classifyRoomError(error);
  if (base != RoomErrorCode.unclassified) return base;

  // 只有 IPv6 地址，且所有尝试都是"网络不可达/地址族不支持"→ 当前网络没有 IPv6。
  final onlyV6 =
      attempts.isNotEmpty &&
      attempts.every((attempt) => attempt.family == 'IPv6');
  final unreachable = attempts.any((attempt) {
    final text = attempt.errorName ?? '';
    return text.contains('Network is unreachable') ||
        text.contains('Address family not supported') ||
        text.contains('Cannot assign requested address');
  });
  if (onlyV6 && unreachable) return RoomErrorCode.ipv6Unreachable;
  return base;
}

/// 升级失败后回探一次等价 HTTP（wss→https、ws→http），把"谁拦了"问清楚。
///
/// 关键点：
/// - `followRedirects = false`：302 必须被看见，而不是被悄悄跟随到登录页；
/// - 抓 `certificate`：能拿到证书 subject/issuer 就说明 **TLS 握手已经成功**，
///   这样"证书问题"和"反代/服务问题"可以分开；
/// - wss 的 https 回探若在 TLS 层失败，再用**明文 http** 回探同一 host:port：
///   能拿到响应就说明这个端口说的是明文 HTTP（`plaintextOnTlsPort`）。
Future<HttpProbe> _probeHttp(
  Uri uri,
  int port,
  Duration timeout, {
  required bool triedTls,
}) async {
  final secure = uri.scheme == 'wss';
  final probeUri = uri.replace(scheme: secure ? 'https' : 'http');
  final first = await _probeOnce(probeUri, timeout);
  if (first.ok || !triedTls) return first;

  // https 回探失败：再确认一次这个端口是不是明文 HTTP。
  final plain = await _probeOnce(uri.replace(scheme: 'http'), timeout);
  if (plain.ok) {
    return HttpProbe(
      scheme: 'http',
      status: plain.status,
      reasonPhrase: plain.reasonPhrase,
      location: plain.location,
      contentType: plain.contentType,
      server: plain.server,
      bodyPrefix: plain.bodyPrefix,
      redirects: plain.redirects,
      errorType: first.errorType,
      errorMessage:
          'TLS probe failed (${first.errorType}: ${first.errorMessage}) '
          'but plain HTTP on the same port answered ${plain.status}',
    );
  }
  return first;
}

Future<HttpProbe> _probeOnce(Uri probe, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(probe).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.connectionHeader, 'close');
    final response = await request.close().timeout(timeout);
    final body = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .take(512)
        .join()
        .timeout(timeout);
    final certificate = response.certificate;
    return HttpProbe(
      scheme: probe.scheme,
      status: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      location: response.headers.value(HttpHeaders.locationHeader) ?? '',
      contentType: response.headers.contentType?.toString() ?? '',
      server: response.headers.value(HttpHeaders.serverHeader) ?? '',
      bodyPrefix: body,
      certSubject: certificate?.subject ?? '',
      certIssuer: certificate?.issuer ?? '',
      redirects: [
        for (final hop in response.redirects)
          '${hop.statusCode} ${hop.location}',
      ],
    );
  } on Object catch (error) {
    return HttpProbe(
      scheme: probe.scheme,
      status: null,
      errorType: error.runtimeType.toString(),
      errorMessage: '$error',
    );
  } finally {
    client.close(force: true);
  }
}
