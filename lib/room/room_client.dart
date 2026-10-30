import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import '../core/platform/foreground_lease.dart';
import 'protocol.dart';
import 'room_endpoint.dart';
import 'room_identity.dart';
import '../ble/reconnect_policy.dart';
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
    ForegroundLease? foreground,
    ReconnectPolicy? reconnectPolicy,
    @visibleForTesting Duration staleAfter = const Duration(seconds: 10),
    @visibleForTesting
    Future<RoomOpenResult> Function(Uri uri, RoomTls tls)? opener,
  }) => RoomClient._(
    displayName,
    memberId ?? RoomIdentity.memberId(),
    sequence,
    tls ?? RoomTls.none,
    foreground ?? ForegroundLease.instance,
    reconnectPolicy ?? const ReconnectPolicy(maxAttempts: 12),
    staleAfter,
    opener ?? (uri, tls) => openRoomChannelResolved(uri, tls: tls),
    logger ?? AppLogger.instance,
  );

  RoomClient._(
    this._displayName,
    this.memberId,
    this._sequence,
    this._tls,
    this._foreground,
    this._retryPolicy,
    this._staleAfter,
    this._opener,
    this._log,
  );

  String _displayName;
  String get displayName => _displayName;
  final String memberId;
  final AppLogger _log;
  final SequenceCounter? _sequence;
  final RoomTls _tls;
  final ForegroundLease _foreground;
  final ReconnectPolicy _retryPolicy;
  final Duration _staleAfter;
  final Future<RoomOpenResult> Function(Uri uri, RoomTls tls) _opener;

  /// 最近一次连接失败的可分辨原因（证书类错误与网络错误分开）。
  RoomErrorCode? lastErrorCode;

  /// 是否钉住了服务端证书指纹。
  bool get tlsPinned => _tls.hasPin;

  /// 最近一次失败的可复制诊断（解析到的地址、逐地址结果、最终归类）。
  RoomDiagnostics? lastDiagnostics;

  /// 服务端最近一次 `error` 消息的 code（`ROOM_FULL` / `SERVER_FULL` / `BAD_MESSAGE`）。
  /// 过去只写日志，界面上看不到 —— 房间满员时用户会以为"连不上"。
  String? lastServerError;
  String? _roomCode;
  String? get roomCode => _roomCode;
  final _members = StreamController<List<MemberState>>.broadcast();
  final _states = StreamController<RoomConnectionState>.broadcast();
  final _byId = <String, MemberState>{};
  WebSocketChannel? _channel;
  Timer? _reportTimer;
  Timer? _heartbeatTimer;
  Timer? _retryTimer;
  StreamSubscription<Object?>? _subscription;
  HeartRateReport? _pending;

  /// 记住最后一次连接目标：掉线后自动重连、以及"从后台回来"时要用。
  Uri? _targetUri;

  /// 用户主动断开后不再自动重连。
  bool _userClosed = true;

  /// 最近一次收到任何服务端消息的时刻（判断 socket 是否已经僵死）。
  DateTime? _lastInboundAt;

  int _retryAttempt = 0;

  Object? lastFailure;
  bool _disposed = false;

  /// 关闭是否由本端发起（区分"用户/我们主动关"与"被对端关掉"）。
  bool _closingLocally = false;

  /// 对端重启类的"立即重连"连续次数（成功后清零）。
  int _immediateRetries = 0;
  static const _maxImmediateRetries = 3;

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
    _userClosed = false;
    _targetUri = uri;
    _retryAttempt = 0;
    _cancelRetry();
    final ok = await _open(uri, isRetry: false);
    if (!ok) {
      // 手动连接失败：把错误抛给 UI，不在后台偷偷重试。
      throw lastFailure ?? StateError('connect failed');
    }
  }

  /// 建立（或重建）连接。返回是否成功；[isRetry] 时不抛异常。
  Future<bool> _open(Uri uri, {required bool isRetry}) async {
    await _closeSocket();
    _setState(RoomConnectionState.connecting);
    if (!isRetry) {
      lastErrorCode = null;
      lastDiagnostics = null;
      lastServerError = null;
    }
    try {
      final opened = await _opener(uri, _tls);
      lastDiagnostics = opened.diagnostics;
      final channel = opened.channel;
      await channel.ready;
      _channel = channel;
      _roomCode = uri.queryParameters['room'];
      _lastInboundAt = DateTime.now();
      _send(RoomMessageType.hello, {
        'memberId': memberId,
        'displayName': _displayName,
      });
      _subscription = channel.stream.listen(
        _onMessage,
        onDone: () => _handleDrop('stream_closed'),
        onError: (Object error, StackTrace stack) {
          _log.error(
            'room',
            'WebSocket receive failed',
            memberId,
            error,
            stack,
          );
          _handleDrop('stream_error');
        },
      );
      _reportTimer = Timer.periodic(AppConfig.reportInterval, (_) => _flush());
      _heartbeatTimer = Timer.periodic(
        AppConfig.heartbeatInterval,
        (_) => _sendPing(),
      );
      _retryAttempt = 0;
      _immediateRetries = 0;
      // 房间连接期间保持前台服务：没有它，切后台后进程被冻结，
      // socket 不再收发（这就是"退后台就断"的根因）。
      await _foreground.acquire('room');
      _setState(RoomConnectionState.connected);
      _log.info(
        'room',
        'room connected lease=room holders=${_foreground.holders.join('+')}',
        deviceId: memberId,
        code: 'room_connected',
      );
      return true;
    } catch (error, stack) {
      _setState(RoomConnectionState.error);
      final code = error is RoomOpenException
          ? error.code
          : classifyRoomError(error);
      if (error is RoomOpenException) lastDiagnostics = error.diagnostics;
      lastErrorCode = code;
      lastFailure = error;
      _log.error(
        'room',
        'WebSocket connect failed code=${code.name} '
            'endpoint=${uri.scheme}://${uri.host}:${uri.port}',
        memberId,
        error,
        stack,
      );
      final diagnostics = lastDiagnostics;
      if (diagnostics != null) {
        _log.error(
          'room',
          'connect diagnostics\n${diagnostics.toClipboardText()}',
          memberId,
          'diagnostics',
        );
      }
      return false;
    }
  }

  /// 意外掉线的统一处理：停定时器、释放前台租约、按退避重连。
  void _handleDrop(String reason) {
    if (_state == RoomConnectionState.disconnected && _retryTimer != null) {
      return;
    }
    _cancelTimers();
    _setState(RoomConnectionState.disconnected);
    unawaited(_foreground.release('room'));
    // 关掉的原因必须写清楚：close code / reason 是判断"谁关的"的唯一证据。
    // 1000/1001 正常关闭，4001+ 服务端自定义，1006 异常断开。
    _log.warn(
      'room',
      'socket dropped reason=$reason '
          'closeCode=${_channel?.closeCode ?? 'none'} '
          "closeReason='${_channel?.closeReason ?? ''}' "
          'initiator=${_closingLocally ? 'local' : 'remote'} '
          'userClosed=$_userClosed lastInbound=${_lastInboundDescription()}',
      deviceId: memberId,
      code: 'ws_drop',
    );
    if (_userClosed) return;
    _scheduleRetry(reason, closeCode: _channel?.closeCode);
  }

  void _scheduleRetry(String reason, {int? closeCode}) {
    if (_userClosed || _targetUri == null || _retryTimer != null) return;

    // 对端"要重启/正在走开"（1001 going away、1012 service restart）不是网络故障：
    // 立刻重连一次，别让用户干等退避。成功一次就把计数清零；连续失败超过
    // [_maxImmediateRetries] 次后回落到正常退避，避免对端反复重启时打爆它。
    if ((closeCode == 1001 || closeCode == 1012) &&
        _immediateRetries < _maxImmediateRetries) {
      _immediateRetries += 1;
      _log.warn(
        'room',
        'peer restarting closeCode=$closeCode — reconnecting immediately '
            '($_immediateRetries/$_maxImmediateRetries)',
        deviceId: memberId,
        code: 'ws_retry_immediate',
      );
      _retryTimer = Timer(Duration.zero, () {
        _retryTimer = null;
        unawaited(_attemptReconnect('peer_restart'));
      });
      return;
    }

    var delay = _retryPolicy.delayFor(_retryAttempt);
    // 1013 = 服务端/房间已满：立刻重连只会更糟，至少等 2 秒。
    if (delay != null &&
        closeCode == 1013 &&
        delay < const Duration(seconds: 2)) {
      delay = const Duration(seconds: 2);
    }
    if (delay == null) {
      _log.warn(
        'room',
        'reconnect exhausted attempts=$_retryAttempt',
        deviceId: memberId,
        code: 'ws_retry_exhausted',
      );
      return;
    }
    _retryAttempt += 1;
    _log.warn(
      'room',
      'reconnect scheduled in ${delay.inMilliseconds}ms '
          'attempt=$_retryAttempt/${_retryPolicy.maxAttempts} reason=$reason',
      deviceId: memberId,
      code: 'ws_retry_scheduled',
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_attemptReconnect('scheduled'));
    });
  }

  Future<void> _attemptReconnect(String trigger) async {
    final uri = _targetUri;
    if (_disposed || _userClosed || uri == null) return;
    final ok = await _open(uri, isRetry: true);
    if (ok) {
      _log.info(
        'room',
        'reconnected trigger=$trigger attempts=$_retryAttempt',
        deviceId: memberId,
        code: 'ws_reconnect_ok',
      );
      return;
    }
    _log.warn(
      'room',
      'reconnect failed trigger=$trigger',
      deviceId: memberId,
      code: 'ws_reconnect_failed',
    );
    _scheduleRetry('retry_failed');
  }

  /// 从后台回到前台时调用：socket 可能已在冻结期间死掉（没有任何回调），
  /// 所以这里主动做一次存活判断，必要时立刻重连 —— 不等退避。
  Future<void> onAppResumed() async {
    if (_disposed || _userClosed || _targetUri == null) return;
    final last = _lastInboundAt;
    final stale = last == null || DateTime.now().difference(last) > _staleAfter;
    if (_state == RoomConnectionState.connected && !stale) {
      _log.info(
        'room',
        'resume: socket alive lastInbound=${_lastInboundDescription()}',
        deviceId: memberId,
        code: 'ws_resume_ok',
      );
      return;
    }
    _log.warn(
      'room',
      'resume: socket stale state=${_state.name} '
          'lastInbound=${_lastInboundDescription()} — reconnecting now',
      deviceId: memberId,
      code: 'ws_resume_reconnect',
    );
    _cancelRetry();
    _retryAttempt = 0;
    await _attemptReconnect('resume');
  }

  String _lastInboundDescription() {
    final last = _lastInboundAt;
    if (last == null) return 'never';
    return '${DateTime.now().difference(last).inMilliseconds}ms ago';
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _cancelTimers() {
    _reportTimer?.cancel();
    _reportTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _closeSocket() async {
    _cancelTimers();
    await _subscription?.cancel();
    _subscription = null;
    try {
      _closingLocally = true;
      await _channel?.sink.close(status.normalClosure);
    } catch (_) {
      // 已经死掉的 socket 关闭会抛，忽略即可。
    } finally {
      _closingLocally = false;
    }
    _channel = null;
  }

  /// 昵称随下一次心跳以可选字段上报。旧服务端忽略该字段，保持 v1 兼容。
  void updateDisplayName(String displayName) {
    if (_displayName == displayName) return;
    _displayName = displayName;
    if (_state == RoomConnectionState.connected) _sendPing();
  }

  void _sendPing() {
    _log.debug('room', 'ws_ping', deviceId: memberId, code: 'ws_ping');
    _send(RoomMessageType.ping, {'displayName': _displayName});
  }

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
    try {
      _channel?.sink.add(
        jsonEncode(RoomEnvelope(type: type, data: data).toJson()),
      );
    } on Object catch (error) {
      // sink 已经死掉时 add 会同步抛：这说明发送侧断了，必须留下证据
      // （旧版这里什么都不记，日志上看起来就是"突然 disconnected"）。
      _log.warn(
        'room',
        'send failed type=${type.name} error=${error.runtimeType}',
        deviceId: memberId,
        code: 'ws_send_failed',
      );
      _handleDrop('send_failed');
    }
  }

  void _onMessage(Object? data) {
    _lastInboundAt = DateTime.now();
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
        case RoomMessageType.pong:
          _log.debug('room', 'ws_pong', deviceId: memberId, code: 'ws_pong');
        case RoomMessageType.error:
          lastServerError = '${envelope.data['code']}';
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
    _userClosed = true;
    _targetUri = null;
    _retryAttempt = 0;
    _cancelRetry();
    await _closeSocket();
    await _foreground.release('room');
    _roomCode = null;
    if (_state != RoomConnectionState.disconnected) {
      _setState(RoomConnectionState.disconnected);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _sequence?.flush();
    await _members.close();
    await _states.close();
  }
}
