import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'protocol.dart';
import 'room_identity.dart';
import 'room_transport.dart';
import 'sequence_counter.dart';

enum RoomConnectionState { disconnected, connecting, connected, error }

final class RoomClient {
  /// [memberId] 由 `IdentityStore` 持久化提供：重启 App 后必须还是同一个值，
  /// 否则服务端会把回来的用户当成新成员（旧成员滞留成幽灵）。
  /// 缺省值仅供测试/演示使用，正式路径必须显式传入。
  factory RoomClient({
    required String displayName,
    String? memberId,
    SequenceCounter? sequence,
    RoomTls? tls,
    AppLogger? logger,
  }) => RoomClient._(
    displayName,
    memberId ?? RoomIdentity.memberId(),
    sequence,
    tls ?? RoomTls.none,
    logger ?? AppLogger.instance,
  );

  RoomClient._(
    this._displayName,
    this.memberId,
    this._sequence,
    this._tls,
    this._log,
  );

  String _displayName;
  String get displayName => _displayName;
  final String memberId;
  final AppLogger _log;
  final SequenceCounter? _sequence;
  final RoomTls _tls;

  /// 最近一次连接失败的可分辨原因（证书类错误与网络错误分开）。
  RoomErrorCode? lastErrorCode;

  /// 是否钉住了服务端证书指纹。
  bool get tlsPinned => _tls.hasPin;
  String? _roomCode;
  String? get roomCode => _roomCode;
  final _members = StreamController<List<MemberState>>.broadcast();
  final _states = StreamController<RoomConnectionState>.broadcast();
  final _byId = <String, MemberState>{};
  WebSocketChannel? _channel;
  Timer? _reportTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<Object?>? _subscription;
  HeartRateReport? _pending;

  /// 缺省（未注入计数器）时退化为进程内自增，仅用于测试。
  int _localSequence = 0;
  RoomConnectionState _state = RoomConnectionState.disconnected;

  Stream<List<MemberState>> get members => _members.stream;
  Stream<RoomConnectionState> get states => _states.stream;
  RoomConnectionState get state => _state;

  void _setState(RoomConnectionState state) {
    _state = state;
    _states.add(state);
    _log.info('room', 'Room connection ${state.name}', deviceId: memberId);
  }

  Future<void> connect(Uri uri) async {
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(uri, 'uri', 'Expected ws:// or wss://');
    }
    await disconnect();
    _setState(RoomConnectionState.connecting);
    lastErrorCode = null;
    var pinMismatch = false;
    try {
      final channel = openRoomChannel(
        uri,
        tls: _tls,
        onPinMismatch: () => pinMismatch = true,
      );
      await channel.ready;
      _channel = channel;
      _roomCode = uri.queryParameters['room'];
      _send(RoomMessageType.hello, {
        'memberId': memberId,
        'displayName': _displayName,
      });
      _subscription = channel.stream.listen(
        _onMessage,
        onDone: () {
          _setState(RoomConnectionState.disconnected);
        },
        onError: (Object error, StackTrace stack) {
          _setState(RoomConnectionState.error);
          _log.error(
            'room',
            'WebSocket receive failed',
            memberId,
            error,
            stack,
          );
        },
      );
      _reportTimer = Timer.periodic(AppConfig.reportInterval, (_) => _flush());
      _heartbeatTimer = Timer.periodic(
        AppConfig.heartbeatInterval,
        (_) => _sendPing(),
      );
      _setState(RoomConnectionState.connected);
    } catch (error, stack) {
      _setState(RoomConnectionState.error);
      final code = classifyRoomError(error, pinMismatch: pinMismatch);
      lastErrorCode = code;
      _log.error(
        'room',
        'WebSocket connect failed code=${code.name} '
            'endpoint=${uri.scheme}://${uri.host}:${uri.port}',
        memberId,
        error,
        stack,
      );
      rethrow;
    }
  }

  /// 昵称随下一次心跳以可选字段上报。旧服务端忽略该字段，保持 v1 兼容。
  void updateDisplayName(String displayName) {
    if (_displayName == displayName) return;
    _displayName = displayName;
    if (_state == RoomConnectionState.connected) _sendPing();
  }

  void _sendPing() =>
      _send(RoomMessageType.ping, {'displayName': _displayName});

  void report({
    required int bpm,
    required List<int> rrIntervalsMs,
    required bool? sensorContact,
    DateTime? measuredAt,
  }) {
    _pending = HeartRateReport(
      memberId: memberId,
      displayName: displayName,
      bpm: bpm,
      rrIntervalsMs: rrIntervalsMs,
      sensorContact: sensorContact,
      sequence: _nextSequence(),
      measuredAt: (measuredAt ?? DateTime.now()).toUtc(),
    );
  }

  void _flush() {
    final pending = _pending;
    if (pending == null || _state != RoomConnectionState.connected) return;
    _pending = null;
    _send(RoomMessageType.heartRate, pending.toJson());
  }

  void _send(RoomMessageType type, Map<String, Object?> data) {
    // Never log envelope payloads: future join credentials belong here.
    _channel?.sink.add(
      jsonEncode(RoomEnvelope(type: type, data: data).toJson()),
    );
  }

  void _onMessage(Object? data) {
    try {
      final envelope = RoomEnvelope.fromJson(
        jsonDecode(data as String) as Map<String, Object?>,
      );
      switch (envelope.type) {
        case RoomMessageType.snapshot:
          _byId.clear();
          for (final raw in envelope.data['members'] as List) {
            final member = _member(raw as Map<String, Object?>);
            _byId[member.report.memberId] = member;
          }
        case RoomMessageType.memberDelta:
          final member = _member(
            envelope.data['member'] as Map<String, Object?>,
          );
          _byId[member.report.memberId] = member;
        case RoomMessageType.error:
          _log.warn(
            'room',
            'Relay error=${envelope.data['code']}',
            deviceId: memberId,
          );
        default:
          break;
      }
      // 自愈：从服务端快照里看到自己的序号更大（本地序号存储被清、或从旧
      // 备份恢复），就把本地计数器抬上去，避免上报被当成旧包一直丢弃。
      final self = _byId[memberId];
      if (self != null) _sequence?.bumpAbove(self.report.sequence);
      _members.add(List.unmodifiable(_byId.values));
    } catch (error, stack) {
      _log.error('room', 'Invalid relay message', memberId, error, stack);
    }
  }

  MemberState _member(Map<String, Object?> json) => MemberState(
    report: HeartRateReport(
      memberId: json['memberId'] as String,
      displayName: json['displayName'] as String,
      bpm: json['bpm'] as int,
      rrIntervalsMs: (json['rrMs'] as List).cast<int>(),
      sensorContact: json['sensorContact'] as bool?,
      sequence: json['sequence'] as int,
      measuredAt: DateTime.parse(json['measuredAt'] as String).toUtc(),
    ),
    lastSeen: DateTime.parse(json['lastSeen'] as String).toUtc(),
    online: json['online'] as bool,
  );

  /// 序号必须跨启动单调递增，否则服务端会把重启后的上报当旧包丢弃。
  int _nextSequence() => _sequence?.next() ?? ++_localSequence;

  Future<void> disconnect() async {
    _reportTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close(status.normalClosure);
    _channel = null;
    _roomCode = null;
    if (_state != RoomConnectionState.disconnected) {
      _setState(RoomConnectionState.disconnected);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _sequence?.flush();
    await _members.close();
    await _states.close();
  }
}
