import 'dart:convert';
import 'dart:io';

/// 测试用最小 WebSocket 房间服务端。
///
/// 本机建房（`RelayServer`）已删除，房间相关测试不再需要真实 relay；这里只提供
/// 「接受升级、可作为对端收发一帧」的能力，够用来验证租约、重连、ping 与掉线分类。
final class WsTestServer {
  WsTestServer._(this._server, this.roomCode);

  /// 起一个监听随机端口的服务端（默认 127.0.0.1，可指定 IPv6 loopback）。
  static Future<WsTestServer> start({
    String roomCode = 'TEST01',
    InternetAddress? address,
  }) async {
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      0,
    );
    final instance = WsTestServer._(server, roomCode);
    server.listen((request) async {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        instance._sockets.add(socket);
        socket.listen(
          (data) {
            // 最小握手：收到 hello 就回 welcome（协议 v1 的既有语义）。
            if (!'$data'.contains('"hello"')) return;
            try {
              socket.add(jsonEncode({'v': 1, 'type': 'welcome'}));
            } catch (_) {
              // 对端刚好在这时关掉了：忽略，测试不需要更精确的握手。
            }
          },
          onDone: () => instance._sockets.remove(socket),
          onError: (_) => instance._sockets.remove(socket),
          cancelOnError: true,
        );
      } catch (_) {
        request.response.statusCode = 400;
        await request.response.close();
      }
    });
    return instance;
  }

  final HttpServer _server;
  final String roomCode;
  final List<WebSocket> _sockets = [];

  int get port => _server.port;

  Uri get uri => Uri(
    scheme: 'ws',
    host: _server.address.host,
    port: port,
    path: '/ws',
    queryParameters: {'room': roomCode},
  );

  List<WebSocket> get sockets => List.unmodifiable(_sockets);

  /// 向所有已连接客户端推一帧（协议 v1 信封）。
  void broadcast(String type, [Map<String, Object?> data = const {}]) {
    final text = jsonEncode({'v': 1, 'type': type, ...data});
    for (final socket in List.of(_sockets)) {
      socket.add(text);
    }
  }

  Future<void> closeAll() async {
    for (final socket in List.of(_sockets)) {
      await socket.close();
    }
    _sockets.clear();
  }

  Future<void> stop() async {
    await closeAll();
    await _server.close(force: true);
  }
}
