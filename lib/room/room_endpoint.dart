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
    this.tlsOk = false,
    this.tlsEvidence = '',
    this.rootErrorType = '',
    this.rootErrorMessage = '',
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

  /// TLS 是否成功建立（独立判据，**不依赖明文旁路探测**）。
  final bool tlsOk;

  /// 判定 TLS 成功的依据，例如"收到合法 HTTP 状态行"或证书 subject。
  final String tlsEvidence;

  /// 剥掉 `WebSocketChannelException` 外壳后的真正异常类型与消息。
  final String rootErrorType;
  final String rootErrorMessage;

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
      ..writeln('tls_ok=${tlsOk ? 'yes' : 'no'}')
      ..writeln('tls_evidence=$tlsEvidence')
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
    if (rootErrorType.isNotEmpty) {
      buffer.writeln('root_error_type=$rootErrorType');
      buffer.writeln(
        'root_error_message=${flatText(rootErrorMessage, limit: 400)}',
      );
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

/// 协议层 ping 间隔。只用于房间长连接；HTTP 回探是普通请求，不受影响。
const _pingInterval = Duration(seconds: 20);

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

  final isSecure = uri.scheme == 'wss';
  var pinMismatch = false;
  // TCP 是否真的建起来过 —— 与"整条连接是否成功"分开记：wss 打明文端口时
  // TCP 通、TLS 失败，这两个事实必须同时出现在诊断里。
  var tcpEstablished = false;

  /// 真正建一条到某个地址的连接。
  ///
  /// **这里必须自己完成 TLS**：dart:io 的 `HttpClient.connectionFactory`
  /// 只用于"自己建 socket"，它**不会**再对返回的 socket 做 TLS（见 SDK
  /// `_http/http_impl.dart` 中 `if (cf != null) connectionTask = cf(...)` 分支：
  /// 只有走默认分支时才会 `SecureSocket.startConnect`）。
  /// 所以 wss 目标必须返回 `SecureSocket`，否则上层会拿明文 socket 发 HTTP。
  Future<Socket> connectAddress(InternetAddress address) async {
    final raw = await Socket.connect(address, port, timeout: perAddress);
    tcpEstablished = true;
    if (!isSecure) return raw;
    final secured = await SecureSocket.secure(
      raw,
      host: uri.host, // SNI + 证书校验都用原始域名，不用 IP
      onBadCertificate: tls.hasPin
          ? (certificate) {
              if (tls.matchesCertificate(certificate.der)) return true;
              pinMismatch = true;
              onPinMismatch?.call();
              return false;
            }
          : null, // 没钉指纹 → 交给系统 CA 严格校验
    );
    return secured;
  }

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
            connect: connectAddress,
          ),
          () {},
        ),
      );
    };

  try {
    final channel = IOWebSocketChannel.connect(
      uri,
      customClient: client,
      // 协议层 ping：识别"链路已经死了但没有 FIN/RST"的假连接。
      // 与 App 层 3s ping、relay 30s pong 超时错开：20s 才发一次协议 ping，
      // 收不到 pong 时 dart:io 会自己关连接（1001），由 RoomClient 按正常退避重连。
      pingInterval: _pingInterval,
    );
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
    final tcpReached = tcpEstablished || attempts.any((attempt) => attempt.ok);
    // 只要 TCP 通过，就一定回探：升级失败后真正的拦截点几乎总是 HTTP 层
    // （302 登录页 / 401 / 403 / 502 / 504）。
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

    // TLS 是否成功：只看**真实连接**与 **https 回探**的事实，
    // 明文回退探测（probe.scheme == 'http'）不参与这个判断。
    final root = unwrapChannelError(error);
    final rootText = '$root';
    final httpsProbeAnswered =
        probeResult != null &&
        probeResult.scheme == 'https' &&
        probeResult.status != null;
    final httpParsed =
        root is HttpException ||
        rootText.contains('HTTP status code') ||
        rootText.contains('was not upgraded') ||
        rootText.contains('Redirect');
    final tlsFailed = isTlsLayerError(root);
    final tlsOk = !tlsFailed && (httpParsed || httpsProbeAnswered);
    final tlsPrefix = uri.scheme == 'wss' ? 'tls handshake completed; ' : '';
    final tlsEvidence = tlsOk
        ? (httpsProbeAnswered
              ? '${tlsPrefix}https probe answered status=${probeResult.status}'
              : '${tlsPrefix}http response parsed; root cause '
                    '${root.runtimeType}: ${flatText(rootText, limit: 120)}')
        : (tlsFailed
              ? 'tls-layer failure: ${root.runtimeType}: '
                    '${flatText(rootText, limit: 120)}'
              : 'no tls response observed');

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
        rootErrorType: root.runtimeType.toString(),
        rootErrorMessage: '$root',
        probe: probeResult,
        tcpReached: tcpReached,
        tlsOk: tlsOk,
        tlsEvidence: tlsEvidence,
      ),
    );
  } finally {
    // 连接池用完即弃：房间连接只需要一条长连接。
    client.close(force: false);
  }
}

/// 明文回退探测里保存了"真正的 https 探测为什么失败"（errorType/errorMessage）。
/// 用它判断：是不是 TLS 层真的没成（决定能否判 `plaintextOnTlsPort`）。
Object probeErrorOf(HttpProbe? probe) {
  if (probe == null || probe.errorType.isEmpty) return const _NoError();
  final text = probe.errorMessage;
  if (probe.errorType.contains('Handshake')) {
    return HandshakeException(text);
  }
  if (probe.errorType.contains('Tls')) return TlsException(text);
  return Exception('${probe.errorType}: $text');
}

final class _NoError {
  const _NoError();
}

/// 归类最终失败。
///
/// 优先级（**别调回去**，两个真实 bug 都是这里踩出来的）：
/// 1. 重定向循环 → `redirectLoop`；
/// 2. 已经收到 HTTP 响应（`HttpException` / `RedirectException` / 非 101 响应）
///    → TLS 一定成功，此时**绝不允许**判成"明文端口"，只能用回探状态码或
///    `handshakeRejected`；
/// 3. TLS 层失败（`HandshakeException` / `TlsException` / 非 TLS 数据）
///    → 若旁路明文探测也有响应，才判 `plaintextOnTlsPort`；
/// 4. 回探状态码（3xx / 401 / 403 / 502 / 504 …）；
/// 5. 异常文本；
/// 6. 兜底 `unclassified`。
RoomErrorCode classifyWithProbe({
  required Object error,
  HttpProbe? probe,
  bool attemptedTls = false,
  bool pinMismatch = false,
}) {
  if (pinMismatch) return RoomErrorCode.certificatePinnedMismatch;
  // 外层是 WebSocketChannelException，真正的原因在 inner。
  final root = unwrapChannelError(error);
  final outerText = '$error';
  final rootText = '$root';

  // 1. 重定向循环：异常文本或逐跳链路证明成环，独立成类。
  final chain = probe?.chain ?? const <String>[];
  final chainLoops =
      chain.any((hop) => hop.startsWith('loop->')) ||
      chain
              .map((hop) => hop.contains(' ') ? hop.split(' ').last : hop)
              .toSet()
              .length <
          chain.length;
  if (rootText.contains('Redirect loop') ||
      outerText.contains('Redirect loop') ||
      rootText.contains('RedirectException') ||
      outerText.contains('RedirectException') ||
      chainLoops) {
    return RoomErrorCode.redirectLoop;
  }

  // 2. HTTP 响应已到 → TLS 一定成功。此时**绝不允许**判"明文端口"：
  //    能拿到状态行/跳转，说明证书握手与 HTTP 都跑通了。
  if (sawHttpResponse(root) || sawHttpResponse(error)) {
    return probe?.code ?? RoomErrorCode.handshakeRejected;
  }

  // 3. **真实连接**在 TLS 层失败：此时任何 HTTP 应答都只能来自明文，
  //    这才是"端口不是 TLS"的判据（判据来自真实连接，不是旁路探测本身）。
  if (isTlsLayerError(root) || isTlsLayerError(error)) {
    if (attemptedTls && probe != null && probe.ok) {
      return RoomErrorCode.plaintextOnTlsPort;
    }
    final base = classifyRoomError(root);
    return base == RoomErrorCode.unclassified
        ? RoomErrorCode.tlsHandshake
        : base;
  }

  // 4. 回探到的状态码优先于异常文本（真机上异常里根本没有状态码）。
  final fromProbe = probe?.code;
  if (fromProbe != null) return fromProbe;

  // 5. 异常文本
  final base = classifyRoomError(root);
  if (base != RoomErrorCode.unclassified) return base;

  // 6. 到这一步还没有结论：**不能**因为"旁路明文探测有响应"就判明文端口 ——
  //    网关对明文请求同样可能回 307/200，那只是旁路说明，不构成判据
  //    （历史上就是把它当成了判据）。交给兜底分类，由诊断信息说明现场。
  return RoomErrorCode.unclassified;
}

/// 归类最终失败：包装 [classifyWithProbe]，并补上"只有 IPv6 且不可达"的判断。
RoomErrorCode _finalCode(
  Object error,
  List<RoomAttempt> attempts, {
  required bool pinMismatch,
  HttpProbe? probe,
  bool attemptedTls = false,
}) {
  final code = classifyWithProbe(
    error: error,
    probe: probe,
    attemptedTls: attemptedTls,
    pinMismatch: pinMismatch,
  );
  if (code != RoomErrorCode.unclassified) return code;

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
  return code;
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
  if (first.status != null &&
      first.status! >= 300 &&
      first.status! < 400 &&
      first.location.isNotEmpty) {
    // 3xx：把逐跳链路走一遍，用来证明"跳到自身"的循环。
    return first.withChain(await probeRedirectChain(probeUri, timeout));
  }
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

/// 手动逐跳跟随重定向（最多 [maxHops] 跳），只用于**说明**，不参与连接。
Future<List<String>> probeRedirectChain(
  Uri start,
  Duration timeout, {
  int maxHops = 5,
}) async {
  final hops = <String>[];
  final visited = <String>{start.toString()};
  var current = start;
  for (var i = 0; i < maxHops; i++) {
    final probe = await _probeOnce(current, timeout);
    if (probe.status == null) {
      hops.add('error ${probe.errorType} $current');
      return hops;
    }
    hops.add('${probe.status} $current');
    if (probe.location.isEmpty) return hops;
    final next = current.resolve(probe.location);
    if (!visited.add(next.toString())) {
      hops.add('loop-> $next');
      return hops;
    }
    current = next;
  }
  hops.add('...(超过 $maxHops 跳)');
  return hops;
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
