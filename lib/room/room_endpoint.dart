import 'dart:async';
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
    this.errorCode,
  });

  final String address;

  /// `IPv6` / `IPv4`
  final String family;
  final Duration elapsed;
  final String? errorName;
  final RoomErrorCode? errorCode;

  bool get ok => errorName == null;

  String describe() => ok
      ? '$family $address ok ${elapsed.inMilliseconds}ms'
      : '$family $address ${errorCode?.name ?? 'unknown'} '
            '"${errorName ?? ''}" ${elapsed.inMilliseconds}ms';
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
  });

  final String scheme;
  final String host;
  final int port;
  final List<String> resolved;
  final List<RoomAttempt> attempts;
  final RoomErrorCode code;

  /// IPv6 字面量要加方括号，否则拼出来的 URL 是错的。
  String get endpoint {
    final literal = host.contains(':') ? '[$host]' : host;
    return '$scheme://$literal:$port';
  }

  String toClipboardText() {
    final buffer = StringBuffer()
      ..writeln('endpoint=$endpoint')
      ..writeln('result=${code.name}')
      ..writeln(
        'resolved=${resolved.isEmpty ? '(none)' : resolved.join(', ')}',
      );
    for (final attempt in attempts) {
      buffer.writeln('attempt=${attempt.describe()}');
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
        code: RoomErrorCode.unknown,
      ),
    );
  } on Object catch (error) {
    var code = _finalCode(error, attempts, pinMismatch: pinMismatch);
    // 升级失败时再回探一次 HTTP 状态码：路径/房间号拼错会拿到 400/404，
    // 这两个原因必须能和"反向代理没配 upgrade"分开。
    if (code == RoomErrorCode.handshakeRejected) {
      final status = await _probeHttpStatus(uri, perAddress);
      if (status == 400) code = RoomErrorCode.badRequest;
      if (status == 404) code = RoomErrorCode.endpointNotFound;
    }
    throw RoomOpenException(
      code,
      RoomDiagnostics(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        resolved: resolved,
        attempts: attempts,
        code: code,
      ),
    );
  } finally {
    // 连接池用完即弃：房间连接只需要一条长连接。
    client.close(force: false);
  }
}

/// 归类最终失败：先看"是不是网络根本没有 IPv6"，否则按异常文本分类。
RoomErrorCode _finalCode(
  Object error,
  List<RoomAttempt> attempts, {
  required bool pinMismatch,
}) {
  if (pinMismatch) return RoomErrorCode.certificatePinnedMismatch;
  final base = classifyRoomError(error);
  if (base != RoomErrorCode.unknown) return base;
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

/// 升级失败后回探一次普通 HTTP 状态码（4096 之类的代理错误也会走到这里）。
/// 只用于把失败原因说清楚，不影响正常连接路径。
Future<int?> _probeHttpStatus(Uri uri, Duration timeout) async {
  // HttpClient 不认 ws/wss，回探要走等价的 http/https。
  final probe = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(probe).timeout(timeout);
    final response = await request.close().timeout(timeout);
    final status = response.statusCode;
    await response.drain<void>().timeout(timeout);
    return status;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
