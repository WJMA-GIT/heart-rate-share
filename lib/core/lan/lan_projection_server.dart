import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_logger.dart';
import '../../room/protocol.dart';

/// 手机侧「投射到局域网」：在手机里起一个**只监听内网**的 WebSocket 服务，
/// 说和中继完全一样的 v1 协议（hello/welcome、heartRate、ping/pong、
/// snapshot/memberDelta），所以 PC 端可以直接复用现有的 `RoomClient`。
///
/// 安全边界：
/// - 只接受私有网段/回环来源的连接（公网地址直接关掉）；
/// - 必须带正确的 `room` 参数，房间码由手机生成；
/// - 单 IP 最多 4 条连接，总数 16；空闲 2 分钟回收成员（与中继一致）；
/// - 关掉开关时关服务、关广播、断开所有客户端（不留监听端口）。
final class LanProjectionServer {
  LanProjectionServer({
    AppLogger? logger,
    this.port = defaultPort,
    this.beaconPort = defaultBeaconPort,
    this.beaconInterval = const Duration(seconds: 3),
    this.maxClients = 16,
    this.maxPerAddress = 4,
    this.offlineAfter = const Duration(seconds: 5),
  }) : _log = logger ?? AppLogger.instance;

  static const defaultPort = 8770;
  static const defaultBeaconPort = 8771;

  final AppLogger _log;
  final int port;
  final int beaconPort;
  final Duration beaconInterval;
  final int maxClients;
  final int maxPerAddress;
  final Duration offlineAfter;

  HttpServer? _server;
  RawDatagramSocket? _beacon;
  Timer? _beaconTimer;
  Timer? _tickTimer;
  final _clients = <WebSocket>[];
  final _perAddress = <String, int>{};
  final _members = <String, _LanMember>{};

  bool get isRunning => _server != null;
  int get portInUse => _server?.port ?? 0;
  int get connectionCount => _clients.length;
  int get memberCount => _members.length;

  String roomCode = '';
  String displayName = '';

  /// 手机自己的采样与房间快照都从这里进来（AppState 负责调用）。
  void publishOwnSample({
    required String memberId,
    required String name,
    required int bpm,
    required List<int> rrMs,
    required bool? sensorContact,
    required int sequence,
    required DateTime measuredAt,
  }) {
    _upsert(
      _LanMember(
        memberId: memberId,
        displayName: name,
        bpm: bpm,
        rrMs: rrMs,
        sensorContact: sensorContact,
        sequence: sequence,
        measuredAt: measuredAt,
        lastSeen: DateTime.now(),
        online: true,
      ),
    );
  }

  /// 云端房间里其他成员的快照（手机在房间里时转给局域网客户端）。
  void publishRoomMembers(Iterable<MemberState> members) {
    for (final member in members) {
      final report = member.report;
      _upsert(
        _LanMember(
          memberId: report.memberId,
          displayName: report.displayName,
          bpm: report.bpm,
          rrMs: report.rrIntervalsMs,
          sensorContact: report.sensorContact,
          sequence: report.sequence,
          measuredAt: report.measuredAt,
          lastSeen: member.lastSeen,
          online: member.online,
        ),
      );
    }
  }

  Future<bool> start({required String room, required String name}) async {
    if (isRunning) return true;
    roomCode = room;
    displayName = name;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server = server;
      server.listen(
        _handleRequest,
        onError: (Object error) {
          _log.warn('lan', 'listener error: $error', code: 'lan_listen_error');
        },
      );
      await _startBeacon();
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _log.info(
        'lan',
        'projection started room=$room port=${server.port} beacon=$beaconPort',
        code: 'lan_started',
      );
      return true;
    } catch (error, stack) {
      _log.error('lan', 'start failed', null, error, stack);
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    for (final client in List<WebSocket>.of(_clients)) {
      await client.close(1001, 'projection stopped').catchError((_) {});
    }
    _clients.clear();
    _perAddress.clear();
    _members.clear();
    try {
      _beacon?.close();
    } catch (_) {}
    _beacon = null;
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
      _log.info('lan', 'projection stopped', code: 'lan_stopped');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final remote = request.connectionInfo?.remoteAddress;
    final remoteKey = remote?.address ?? 'unknown';
    if (remote == null || !_isPrivateOrLoopback(remote)) {
      // 内网之外一律拒绝：这个服务不允许出现在公网。
      _log.warn(
        'lan',
        'rejected non-private peer: $remoteKey',
        code: 'lan_reject_public',
      );
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.uri.path != '/ws') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['room'] != roomCode) {
      _log.warn(
        'lan',
        'rejected room mismatch from $remoteKey',
        code: 'lan_reject_room',
      );
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (_clients.length >= maxClients ||
        (_perAddress[remoteKey] ?? 0) >= maxPerAddress) {
      _log.warn(
        'lan',
        'rejected too many connections from $remoteKey',
        code: 'lan_reject_limit',
      );
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    _clients.add(socket);
    _perAddress[remoteKey] = (_perAddress[remoteKey] ?? 0) + 1;
    _log.info(
      'lan',
      'client connected from $remoteKey (clients=${_clients.length})',
      code: 'lan_client_connected',
    );
    socket.listen(
      (data) => _onClientMessage(socket, data),
      onDone: () => _dropClient(socket, remoteKey, 'closed'),
      onError: (Object error) =>
          _dropClient(socket, remoteKey, 'error: $error'),
      cancelOnError: true,
    );
  }

  void _dropClient(WebSocket socket, String remoteKey, String reason) {
    _clients.remove(socket);
    final left = (_perAddress[remoteKey] ?? 1) - 1;
    if (left <= 0) {
      _perAddress.remove(remoteKey);
    } else {
      _perAddress[remoteKey] = left;
    }
    _log.info(
      'lan',
      'client gone ($reason, clients=${_clients.length})',
      code: 'lan_client_closed',
    );
  }

  void _onClientMessage(WebSocket socket, Object? data) {
    RoomEnvelope envelope;
    try {
      envelope = RoomEnvelope.fromJson(
        jsonDecode('$data') as Map<String, Object?>,
      );
    } catch (_) {
      _send(socket, 'error', {'code': 'BAD_MESSAGE'});
      return;
    }
    switch (envelope.type) {
      case RoomMessageType.hello:
        _send(socket, 'welcome', {});
        _sendSnapshot(socket);
      case RoomMessageType.ping:
        _send(socket, 'pong', {});
      case RoomMessageType.heartRate:
        final report = _parseReport(envelope.data);
        if (report == null) {
          _send(socket, 'error', {'code': 'BAD_MESSAGE'});
          return;
        }
        if (_members.length >= 20 && !_members.containsKey(report.memberId)) {
          _send(socket, 'error', {'code': 'ROOM_FULL'});
          return;
        }
        _upsert(report);
      default:
        _send(socket, 'error', {'code': 'BAD_MESSAGE'});
    }
  }

  _LanMember? _parseReport(Map<String, Object?> json) {
    try {
      final memberId = json['memberId'] as String;
      final name = json['displayName'] as String;
      final bpm = json['bpm'] as int;
      final rr = (json['rrMs'] as List).cast<int>();
      final sequence = json['sequence'] as int;
      final measuredAt = DateTime.parse(json['measuredAt'] as String).toUtc();
      final contact = json['sensorContact'] as bool?;
      return _LanMember(
        memberId: memberId,
        displayName: name,
        bpm: bpm,
        rrMs: rr,
        sensorContact: contact,
        sequence: sequence,
        measuredAt: measuredAt,
        lastSeen: DateTime.now(),
        online: true,
      );
    } catch (_) {
      return null;
    }
  }

  void _upsert(_LanMember member) {
    final existing = _members[member.memberId];
    if (existing != null && member.sequence <= existing.sequence) return;
    _members[member.memberId] = member;
    _broadcast('memberDelta', {'member': member.toJson()});
  }

  void _tick() {
    final now = DateTime.now();
    final changed = <_LanMember>[];
    for (final entry in _members.entries.toList()) {
      final member = entry.value;
      final stale = now.difference(member.lastSeen) > offlineAfter;
      if (member.online && stale) {
        member.online = false;
        changed.add(member);
      }
      if (now.difference(member.lastSeen) > const Duration(minutes: 2)) {
        _members.remove(entry.key);
      }
    }
    for (final member in changed) {
      _broadcast('memberDelta', {'member': member.toJson()});
    }
    _broadcast('snapshot', {'members': snapshot()});
  }

  List<Map<String, Object?>> snapshot() {
    final list = [for (final member in _members.values) member.toJson()];
    list.sort(
      (a, b) => ('${a['displayName']}').compareTo('${b['displayName']}'),
    );
    return list;
  }

  void _sendSnapshot(WebSocket socket) =>
      _send(socket, 'snapshot', {'members': snapshot()});

  void _broadcast(String type, Map<String, Object?> data) {
    for (final client in List<WebSocket>.of(_clients)) {
      _send(client, type, data);
    }
  }

  void _send(WebSocket socket, String type, Map<String, Object?> data) {
    try {
      socket.add(jsonEncode({'v': 1, 'type': type, ...data}));
    } catch (_) {
      // 对端刚好掉了：交给 onDone 清理
    }
  }

  Future<void> _startBeacon() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      _beacon = socket;
      _beaconTimer = Timer.periodic(beaconInterval, (_) {
        final payload = utf8.encode(
          jsonEncode({
            'app': 'heart-rate-share',
            'v': 1,
            'room': roomCode,
            'port': portInUse,
            'name': displayName,
            'platform': 'android',
            'protocol': 1,
            'members': _members.length,
          }),
        );
        try {
          socket.send(payload, InternetAddress('255.255.255.255'), beaconPort);
        } catch (_) {
          // 某些网络不允许广播：忽略，PC 侧仍可手动填 IP
        }
      });
    } catch (error) {
      _log.warn('lan', 'beacon unavailable: $error', code: 'lan_beacon_error');
    }
  }

  static bool isPrivateOrLoopbackAddress(InternetAddress address) =>
      _isPrivateOrLoopback(address);

  static bool _isPrivateOrLoopback(InternetAddress address) {
    if (address.isLoopback) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      if (bytes[0] == 10) return true;
      if (bytes[0] == 192 && bytes[1] == 168) return true;
      if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
      if (bytes[0] == 169 && bytes[1] == 254) return true; // link-local
      return false;
    }
    // IPv6: fc00::/7 唯一本地地址 + fe80::/10 链路本地
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      if ((bytes[0] & 0xfe) == 0xfc) return true;
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true;
    }
    return false;
  }
}

final class _LanMember {
  _LanMember({
    required this.memberId,
    required this.displayName,
    required this.bpm,
    required this.rrMs,
    required this.sensorContact,
    required this.sequence,
    required this.measuredAt,
    required this.lastSeen,
    required this.online,
  });

  final String memberId;
  final String displayName;
  int bpm;
  List<int> rrMs;
  bool? sensorContact;
  int sequence;
  DateTime measuredAt;
  DateTime lastSeen;
  bool online;

  Map<String, Object?> toJson() => {
    'memberId': memberId,
    'displayName': displayName,
    'bpm': bpm,
    'rrMs': rrMs,
    'sensorContact': sensorContact,
    'sequence': sequence,
    'measuredAt': measuredAt.toUtc().toIso8601String(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'online': online,
  };
}
