import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'protocol.dart';
import 'room_identity.dart';

enum RoomConnectionState { disconnected, connecting, connected, error }

final class RoomClient {
  factory RoomClient({required String displayName, AppLogger? logger}) =>
      RoomClient._(displayName, logger ?? AppLogger.instance);

  RoomClient._(this._displayName, this._log)
    : memberId = RoomIdentity.memberId();

  String _displayName;
  String get displayName => _displayName;
  final String memberId;
  final AppLogger _log;
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
  int _sequence = 0;
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
    try {
      final channel = WebSocketChannel.connect(uri);
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
      _log.error('room', 'WebSocket connect failed', memberId, error, stack);
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
      sequence: ++_sequence,
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
    await _members.close();
    await _states.close();
  }
}
