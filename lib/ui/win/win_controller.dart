import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_logger.dart';
import '../../core/lan/lan_projection_server.dart';
import '../../room/protocol.dart';
import '../../room/room_client.dart';
import '../widgets/heart_rate_chart.dart';

/// 局域网里发现的一台手机（来自手机的 UDP 播发）。
final class LanPeer {
  LanPeer({
    required this.name,
    required this.room,
    required this.host,
    required this.port,
  });

  final String name;
  final String room;
  final String host;
  final int port;
  DateTime lastSeen = DateTime.now();

  String get id => '$host:$port/$room';
  Uri get uri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: '/ws',
    queryParameters: {'room': room},
  );
}

/// Windows 客户端的数据层：发现手机 → 连上手机的内网 WS → 把成员心率喂给折线。
///
/// 用的是**同一个** `RoomClient`（协议 v1 没变），所以 PC 端不需要第二套协议实现。
final class WinController extends ChangeNotifier {
  WinController({RoomClient? room, AppLogger? logger})
    : _room =
          room ?? RoomClient(displayName: 'Windows', memberId: _pcMemberId()),
      _log = logger ?? AppLogger.instance {
    _subs.add(
      _room.members.listen((members) {
        _members = members;
        _track(members);
        notifyListeners();
      }),
    );
    _subs.add(_room.states.listen((_) => notifyListeners()));
  }

  static String _pcMemberId() {
    // 仅供局域网房间去重；不含任何设备标识。
    final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'win-${rand.padLeft(12, '0').substring(0, 12)}';
  }

  final RoomClient _room;
  final AppLogger _log;
  final List<StreamSubscription<Object?>> _subs = [];
  final List<LanPeer> _peers = [];
  final Map<String, HeartRateSeries> _series = {};
  final Map<String, DateTime> _lastSampleAt = {};
  RawDatagramSocket? _udp;
  List<MemberState> _members = const [];
  String? _connectedRoom;
  String? _error;

  bool scanning = false;
  bool backgroundTransparent = true;

  List<LanPeer> get peers => List.unmodifiable(_peers);
  RoomConnectionState get state => _room.state;
  bool get connected => _room.state == RoomConnectionState.connected;
  String? get error => _error;
  String? get connectedRoom => _connectedRoom;
  List<MemberState> get members => _members;

  /// 当前走的是哪条通路（Phase 1 只有局域网；BLE 直连是 Phase 2）。
  String get transportLabel => connected ? '局域网投射' : '未连接';

  HeartRateSeries seriesFor(String memberId) =>
      _series.putIfAbsent(memberId, HeartRateSeries.new);

  int? liveBpm(MemberState member) {
    final last = _lastSampleAt[member.report.memberId];
    if (last == null) return null;
    if (DateTime.now().difference(last) > const Duration(seconds: 5)) {
      return null;
    }
    return member.report.bpm;
  }

  /// 监听手机侧的 UDP 播发（8771）。10 秒没再听到就当离线。
  Future<void> startDiscovery() async {
    if (_udp != null) return;
    scanning = true;
    notifyListeners();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanProjectionServer.defaultBeaconPort,
      );
      socket.broadcastEnabled = true;
      _udp = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        _onBeacon(datagram);
      });
      Timer.periodic(const Duration(seconds: 5), (_) {
        final before = _peers.length;
        _peers.removeWhere(
          (p) =>
              DateTime.now().difference(p.lastSeen) >
              const Duration(seconds: 12),
        );
        if (_peers.length != before) {
          notifyListeners();
        }
      });
    } catch (error, stack) {
      _log.error('win', 'discovery failed', null, error, stack);
      _error = '无法监听局域网广播（端口 8771 可能被占用）';
    }
    scanning = false;
    notifyListeners();
  }

  void _onBeacon(Datagram datagram) {
    try {
      final json =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
      if (json['app'] != 'heart-rate-share') return;
      final room = json['room'] as String? ?? '';
      final port = json['port'] as int? ?? 0;
      if (room.isEmpty || port <= 0) return;
      final host = datagram.address.address;
      final peer = LanPeer(
        name: (json['name'] as String?) ?? host,
        room: room,
        host: host,
        port: port,
      );
      final index = _peers.indexWhere((p) => p.id == peer.id);
      if (index >= 0) {
        _peers[index].lastSeen = DateTime.now();
      } else {
        _peers.add(peer);
      }
      notifyListeners();
    } catch (_) {
      // 不是我们的包，忽略
    }
  }

  Future<bool> connect(LanPeer peer) =>
      connectTo(peer.host, peer.port, peer.room);

  Future<bool> connectTo(String host, int port, String room) async {
    _error = null;
    _connectedRoom = room;
    notifyListeners();
    final uri = Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: '/ws',
      queryParameters: {'room': room},
    );
    try {
      await _room.connect(uri);
      _log.info(
        'win',
        'connected to $host:$port room=$room',
        code: 'win_connected',
      );
      notifyListeners();
      return true;
    } catch (error) {
      _error = '连不上 $host:$port（房间码或 Wi-Fi 不对？）';
      _log.warn('win', 'connect failed: $error', code: 'win_connect_failed');
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect() async {
    await _room.disconnect();
    _connectedRoom = null;
    _series.clear();
    _lastSampleAt.clear();
    notifyListeners();
  }

  void toggleBackground() {
    backgroundTransparent = !backgroundTransparent;
    notifyListeners();
  }

  void _track(List<MemberState> members) {
    final now = DateTime.now();
    for (final member in members) {
      final report = member.report;
      if (!member.online) continue;
      final series = seriesFor(report.memberId);
      final last = series.latest;
      if (last != null && !report.measuredAt.isAfter(last.at)) continue;
      series.add(HeartRatePoint(at: report.measuredAt, bpm: report.bpm));
      _lastSampleAt[report.memberId] = now;
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _udp?.close();
    _udp = null;
    unawaited(_room.dispose());
    super.dispose();
  }
}
