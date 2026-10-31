import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ble/ble_models.dart';
import '../../ble/heart_rate_service.dart';
import '../../ble/heart_rate_sample.dart';
import '../../core/lan/lan_projection_server.dart';
import '../../core/logging/app_logger.dart';
import '../../room/protocol.dart';
import '../../room/room_client.dart';
import '../widgets/heart_rate_chart.dart';

/// 局域网里发现的一台手机（来自手机的 UDP 播发）。
///
/// 界面上只用 [name] / [platform] / [members] / 状态；房间码只在本对象内部用，
/// 不展示给用户（用户拍板：不需要房间码）。
final class LanPeer {
  LanPeer({
    required this.name,
    required this.room,
    required this.host,
    required this.port,
    this.platform = 'android',
    this.members = 0,
  });

  final String name;
  final String room;
  final String host;
  final int port;
  final String platform;
  final int members;
  DateTime lastSeen = DateTime.now();

  String get id => '$host:$port';

  /// 不展示给用户，仅用于连接时带上（服务端已不校验）。
  Uri get uri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: '/ws',
    queryParameters: {'room': room},
  );
}

enum WinTransport { none, ble, lan }

/// Windows 客户端数据层：两条通路
/// - **BLE 直连**（有蓝牙时优先）：复用 `HeartRateService`（flutter_blue_plus +
///   Windows endorsed 的 WinRT 后端），扫描 0x180D → 连接 → 订阅 0x2A37；
/// - **局域网投射**（没有蓝牙/没有设备时）：UDP 发现手机 → 点选 → 连手机内网 WS。
final class WinController extends ChangeNotifier {
  WinController({
    RoomClient? room,
    HeartRateService? ble,
    AppLogger? logger,
    SharedPreferences? preferences,
    this.preview = false,
  }) : _room =
           room ?? RoomClient(displayName: 'Windows', memberId: _pcMemberId()),
       _injectedBle = ble,
       _log = logger ?? AppLogger.instance,
       _prefs = preferences {
    _subs.add(
      _room.members.listen((members) {
        _members = members;
        _track(members);
        notifyListeners();
      }),
    );
    _subs.add(_room.states.listen((_) => notifyListeners()));
  }

  /// BLE 服务惰性创建：插件在 Windows 上初始化失败（无适配器/权限/后端不支持）
  /// 只影响蓝牙这一条通路，绝不能把整个窗口带崩。
  HeartRateService? ensureBle({bool force = false}) {
    if (_ble != null) return _ble;
    if (_bleFailed && !force) return null;
    try {
      final service = _injectedBle ?? HeartRateService();
      _subs.add(
        service.snapshots.listen((snapshot) {
          _bleSnapshot = snapshot;
          notifyListeners();
        }),
      );
      _subs.add(service.samples.listen(_onBleSample));
      _ble = service;
      _bleFailed = false;
      _log.info('win', 'ble service ready', code: 'win_ble_ready');
      return service;
    } catch (error, stack) {
      _bleFailed = true;
      _error = '蓝牙不可用：$error（可以只用局域网投射）';
      _log.error('win', 'ble init failed', null, error, stack);
      notifyListeners();
      return null;
    }
  }

  static const lastPeerKey = 'win.lastPeer';

  static String _pcMemberId() {
    final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'win-${rand.padLeft(12, '0').substring(0, 12)}';
  }

  final RoomClient _room;
  final HeartRateService? _injectedBle;

  /// `--connected-preview`：注入 mock 成员并强制「已连接」（CI 冒烟用）。
  final bool preview;
  bool _previewOnline = true;
  Timer? _previewTick;
  Timer? _previewCycle;
  HeartRateService? _ble;
  bool _bleFailed = false;
  final AppLogger _log;
  final SharedPreferences? _prefs;
  final List<StreamSubscription<Object?>> _subs = [];
  final List<LanPeer> _peers = [];
  final Map<String, HeartRateSeries> _series = {};
  final Map<String, DateTime> _lastSampleAt = {};
  RawDatagramSocket? _udp;
  List<MemberState> _members = const [];
  BleSnapshot _bleSnapshot = const BleSnapshot();
  HeartRateSeries _bleSeries = HeartRateSeries();
  int? _bleBpm;
  DateTime? _bleLastSampleAt;
  String? _connectedPeerName;
  String? _error;

  bool scanning = false;
  bool backgroundTransparent = true;
  WinTransport transport = WinTransport.none;

  List<LanPeer> get peers => List.unmodifiable(_peers);
  RoomConnectionState get roomState => _room.state;
  BleSnapshot get ble => _bleSnapshot;
  bool get connected {
    if (preview) return _previewOnline;
    return transport == WinTransport.ble ||
        _room.state == RoomConnectionState.connected;
  }

  String? get error => _error;

  /// 界面显示的通路（必须能一眼看出走的是哪条）。
  String get transportLabel {
    switch (transport) {
      case WinTransport.ble:
        final id = _bleSnapshot.connectedDeviceId;
        final name = _bleSnapshot.devices
            .where((d) => d.id == id)
            .map((d) => d.name.isEmpty ? d.id : d.name)
            .firstOrNull;
        return '蓝牙直连（${name ?? id ?? '设备'}）';
      case WinTransport.lan:
        return '局域网（${_connectedPeerName ?? '手机'}）';
      case WinTransport.none:
        return '未连接';
    }
  }

  /// 蓝牙可用（适配器打开）时优先 BLE。
  bool get bleAdapterOn =>
      _bleSnapshot.adapterState == 'on' ||
      _bleSnapshot.adapterState == 'poweredOn';

  /// 排查开关：默认只列广播里带心率服务 0x180D 的设备（和手机端 onlyHrs 一致），
  /// 打开后全量显示（设置页里的隐藏兜底，不进主界面）。
  bool bleDebug = false;

  /// 界面用：只保留确认为心率设备的条目（`isHrsCandidate` = 广播带 0x180D）。
  List<dynamic> get bleDevices {
    final all = _bleSnapshot.devices;
    if (bleDebug) return all;
    return [
      for (final device in all)
        if (device.isHrsCandidate) device,
    ];
  }

  /// 被过滤掉的条数：空状态里提示「可以打开全量显示排查」。
  int get hiddenBleDeviceCount =>
      bleDebug ? 0 : _bleSnapshot.devices.length - bleDevices.length;

  HeartRateSeries seriesFor(String memberId) =>
      _series.putIfAbsent(memberId, HeartRateSeries.new);

  /// BLE 自己的那一行（成员名 = 设备名）。
  HeartRateSeries get ownSeries => _bleSeries;
  int? get ownBpm {
    final last = _bleLastSampleAt;
    if (last == null) return null;
    if (DateTime.now().difference(last) > const Duration(seconds: 5)) {
      return null;
    }
    return _bleBpm;
  }

  /// 局域网房间里的成员（不含 BLE 自己那行）。
  List<MemberState> get members => _members;

  /// 局域网行的实时心率（5 秒没更新就当没有）。
  int? liveBpm(MemberState member) {
    final last = _lastSampleAt[member.report.memberId];
    if (last == null) return null;
    if (DateTime.now().difference(last) > const Duration(seconds: 5)) {
      return null;
    }
    return member.report.bpm;
  }

  // ------------------------------------------------------------------ 发现

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
        if (_peers.length != before) notifyListeners();
      });
    } catch (error, stack) {
      _log.error('win', 'discovery failed', null, error, stack);
      _error = '无法监听局域网广播（端口 8771 被占用或被安全软件拦截）';
    }
    scanning = false;
    notifyListeners();
  }

  void _onBeacon(Datagram datagram) {
    try {
      final json =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
      if (json['app'] != 'heart-rate-share') return;
      final port = json['port'] as int? ?? 0;
      if (port <= 0) return;
      final host = datagram.address.address;
      final peer = LanPeer(
        name: (json['name'] as String?) ?? host,
        room: (json['room'] as String?) ?? '',
        host: host,
        port: port,
        platform: (json['platform'] as String?) ?? 'android',
        members: (json['members'] as int?) ?? 0,
      );
      final index = _peers.indexWhere((p) => p.id == peer.id);
      if (index >= 0) {
        _peers[index] = peer..lastSeen = DateTime.now();
      } else {
        _peers.add(peer);
      }
      notifyListeners();
    } catch (_) {
      // 不是我们的包
    }
  }

  /// 上次选过的设备（自动重连用）。
  String? get lastPeerId => _prefs?.getString(lastPeerKey);

  // ------------------------------------------------------------------ 连接

  Future<bool> connectPeer(LanPeer peer) async {
    await _ble?.disconnect().catchError((_) {});
    _error = null;
    transport = WinTransport.lan;
    _connectedPeerName = peer.name;
    notifyListeners();
    try {
      await _room.connect(peer.uri);
      await _prefs?.setString(lastPeerKey, peer.id);
      _log.info(
        'win',
        'lan connected ${peer.host}:${peer.port}',
        code: 'win_lan_connected',
      );
      notifyListeners();
      return true;
    } catch (error) {
      _error = '连不上 ${peer.name}（${peer.host}:${peer.port}）——检查 Wi-Fi 是否同一网段';
      _log.warn('win', 'lan connect failed: $error', code: 'win_lan_failed');
      transport = WinTransport.none;
      notifyListeners();
      return false;
    }
  }

  /// 手动兜底：直接填 IP:端口（广播被挡时用）。
  Future<bool> connectManual(String address) async {
    final parts = address.trim().split(':');
    final host = parts.first;
    final port = parts.length > 1
        ? int.tryParse(parts[1]) ?? LanProjectionServer.defaultPort
        : LanProjectionServer.defaultPort;
    return connectPeer(LanPeer(name: host, room: '', host: host, port: port));
  }

  /// BLE：扫描心率设备（插件侧已按 0x180D 过滤）。
  Future<void> scanBle() async {
    _error = null;
    notifyListeners();
    final ble = ensureBle();
    if (ble == null) return;
    try {
      await ble.scan(onlyHrs: false);
    } catch (error) {
      _error = '蓝牙扫描失败：$error（确认系统蓝牙已打开、设备已配对/在附近）';
      _log.warn('win', 'ble scan failed: $error', code: 'win_ble_scan_failed');
    }
    notifyListeners();
  }

  Future<bool> connectBle(String deviceId) async {
    _error = null;
    final ble = ensureBle();
    if (ble == null) return false;
    try {
      await _room.disconnect();
      await ble.connect(deviceId);
      transport = WinTransport.ble;
      _connectedPeerName = null;
      notifyListeners();
      return true;
    } catch (error) {
      _error = '蓝牙连接失败：$error';
      transport = WinTransport.none;
      notifyListeners();
      return false;
    }
  }

  void _onBleSample(HeartRateSample sample) {
    final last = _bleSeries.latest;
    if (last == null || sample.receivedAt.isAfter(last.at)) {
      _bleSeries.add(HeartRatePoint(at: sample.receivedAt, bpm: sample.bpm));
    }
    _bleBpm = sample.bpm;
    _bleLastSampleAt = DateTime.now();
    if (transport != WinTransport.ble) transport = WinTransport.ble;
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    await _room.disconnect().catchError((_) {});
    await _ble?.disconnect().catchError((_) {});
    _connectedPeerName = null;
    _series.clear();
    _lastSampleAt.clear();
    _bleSeries = HeartRateSeries();
    _bleBpm = null;
    _bleLastSampleAt = null;
    transport = WinTransport.none;
    notifyListeners();
  }

  /// 打开日志目录：不用让用户自己去 %LOCALAPPDATA% 里翻。
  Future<void> openLogFolder() async {
    final local = Platform.environment['LOCALAPPDATA'];
    final dir = local == null ? null : Directory('$local\\heartrate\\logs');
    final target = dir != null && dir.existsSync() ? dir.path : (local ?? '.');
    try {
      await Process.run('explorer.exe', [target]);
    } catch (error) {
      _log.warn(
        'win',
        'open log folder failed: $error',
        code: 'win_open_log_failed',
      );
    }
  }

  void toggleBackground() {
    backgroundTransparent = !backgroundTransparent;
    notifyListeners();
  }

  void toggleBleDebug() {
    bleDebug = !bleDebug;
    notifyListeners();
  }

  // ------------------------------------------------- 预览（--connected-preview）

  /// 没有手机也没有蓝牙设备时，也要把「连接 → 全透明精简态 → 断开」走一遍：
  /// 注入 3 个 mock 成员，每 6 秒切一次连接状态（CI 冒烟据此断言两种界面都出现过）。
  void startPreview() {
    transport = WinTransport.lan;
    _connectedPeerName = '预览设备';
    _previewSample();
    _previewTick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _previewSample(),
    );
    _previewCycle = Timer.periodic(const Duration(seconds: 6), (_) {
      _previewOnline = !_previewOnline;
      notifyListeners();
    });
    _log.info('win', 'preview: mock members on', code: 'win_preview_on');
  }

  static const _previewNames = ['预览一号', '预览二号', '预览三号'];

  void _previewSample() {
    final now = DateTime.now();
    final base = 62 + now.second % 17;
    _members = [
      for (var i = 0; i < _previewNames.length; i++)
        MemberState(
          report: HeartRateReport(
            memberId: 'preview-$i',
            displayName: _previewNames[i],
            bpm: base + i * 3,
            rrIntervalsMs: const [],
            sensorContact: true,
            sequence: now.second,
            measuredAt: now,
          ),
          lastSeen: now,
          online: true,
        ),
    ];
    for (final member in _members) {
      final report = member.report;
      seriesFor(report.memberId).add(HeartRatePoint(at: now, bpm: report.bpm));
      _lastSampleAt[report.memberId] = now;
    }
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
    _previewTick?.cancel();
    _previewCycle?.cancel();
    _udp?.close();
    _udp = null;
    unawaited(_room.dispose());
    unawaited(_ble?.dispose() ?? Future<void>.value());
    super.dispose();
  }
}
