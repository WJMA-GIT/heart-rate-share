import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'protocol.dart';
import 'relay_store.dart';
import 'room_identity.dart';

/// Development relay: room code + unicast WebSocket fan-out.
/// TODO(Production security): replace ws:// with authenticated WSS/TLS before
/// public/store use. Deliberately not claimed as secure in this MVP skeleton.
final class RelayServer {
  RelayServer({AppLogger? logger})
    : store = RelayStore(logger: logger),
      _log = logger ?? AppLogger.instance,
      roomCode = RoomIdentity.shortCode();
  final RelayStore store;
  final AppLogger _log;
  final String roomCode;
  HttpServer? _server;
  final _sockets = <String, WebSocket>{};
  Timer? _pruneTimer;
  Timer? _snapshotTimer;
  bool _stopped = false;

  int get port => _server?.port ?? AppConfig.defaultWebSocketPort;

  String get address =>
      'ws://localhost:${_server?.port ?? AppConfig.defaultWebSocketPort}'
      '${AppConfig.webSocketPath}?room=$roomCode';

  Future<void> start({
    InternetAddress? host,
    int port = AppConfig.defaultWebSocketPort,
  }) async {
    if (_server != null || _stopped) {
      throw StateError('RelayServer instances can only be started once');
    }
    _server = await HttpServer.bind(host ?? InternetAddress.anyIPv4, port);
    _server!.listen(
      _onRequest,
      onError: (Object error, StackTrace stack) {
        _log.error('relay', 'HTTP server error', null, error, stack);
      },
    );
    _pruneTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final before = {
        for (final member in store.members)
          member.report.memberId: member.online,
      };
      final after = store.prune();
      for (final member in after) {
        if (before[member.report.memberId] != member.online) {
          _broadcast(RoomMessageType.memberDelta, {'member': member.toJson()});
        }
      }
    });
    _snapshotTimer = Timer.periodic(AppConfig.snapshotInterval, (_) {
      _broadcast(RoomMessageType.snapshot, {
        'members': store.members.map((member) => member.toJson()).toList(),
      });
    });
    _log.info('relay', 'Relay listening port=${_server!.port} room=$roomCode');
  }

  Future<void> _onRequest(HttpRequest request) async {
    if (request.uri.path != AppConfig.webSocketPath ||
        request.uri.queryParameters['room'] != roomCode) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    String? memberId;
    socket.listen(
      (data) {
        try {
          final envelope = RoomEnvelope.fromJson(
            jsonDecode(data as String) as Map<String, Object?>,
          );
          switch (envelope.type) {
            case RoomMessageType.hello:
              memberId = envelope.data['memberId'] as String?;
              if (memberId == null || memberId!.isEmpty) {
                throw const FormatException('memberId');
              }
              final previousSocket = _sockets[memberId!];
              if (previousSocket != null &&
                  !identical(previousSocket, socket)) {
                // 同一标识重连：旧连接让位，避免一个成员占两条连接。
                _log.info(
                  'relay',
                  'Member reconnected, replacing old socket',
                  deviceId: memberId,
                );
                unawaited(previousSocket.close(4000, 'replaced'));
              }
              _sockets[memberId!] = socket;
              final resumed = store.resume(memberId!);
              _log.info(
                'relay',
                resumed == null
                    ? 'member new'
                    : 'member resumed wasOnline=${resumed.online}',
                deviceId: memberId,
              );
              socket.add(
                jsonEncode(
                  const RoomEnvelope(
                    type: RoomMessageType.welcome,
                    data: {},
                  ).toJson(),
                ),
              );
            case RoomMessageType.heartRate:
              final report = _report(envelope.data);
              if (memberId != report.memberId) {
                throw const FormatException('Member mismatch');
              }
              final state = store.accept(report);
              if (state != null) {
                _broadcast(RoomMessageType.memberDelta, {
                  'member': state.toJson(),
                });
              }
            case RoomMessageType.ping:
              final nextName = _optionalDisplayName(
                envelope.data['displayName'],
              );
              if (memberId != null && nextName != null) {
                final renamed = store.rename(memberId!, nextName);
                if (renamed != null) {
                  _broadcast(RoomMessageType.memberDelta, {
                    'member': renamed.toJson(),
                  });
                }
              }
              socket.add(
                jsonEncode(
                  const RoomEnvelope(
                    type: RoomMessageType.pong,
                    data: {},
                  ).toJson(),
                ),
              );
            default:
              throw FormatException('Client cannot send ${envelope.type.name}');
          }
        } catch (error, stack) {
          _log.error(
            'relay',
            'Bad client message: $error',
            memberId,
            error,
            stack,
          );
          socket.add(
            jsonEncode(
              const RoomEnvelope(
                type: RoomMessageType.error,
                data: {'code': 'BAD_MESSAGE'},
              ).toJson(),
            ),
          );
        }
      },
      onDone: () {
        // 只清理属于这条连接的映射：重连时旧连接关闭不能把新连接的登记删掉。
        if (memberId != null && identical(_sockets[memberId], socket)) {
          _sockets.remove(memberId);
        }
      },
      onError: (Object error, StackTrace stack) {
        _log.error('relay', 'Socket error', memberId, error, stack);
      },
      cancelOnError: true,
    );
  }

  String _displayName(Object? value) {
    final normalized = _optionalDisplayName(value);
    if (normalized == null) {
      throw const FormatException('displayName must be non-empty');
    }
    return normalized;
  }

  String? _optionalDisplayName(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final trimmed = value.trim();
    return trimmed.length <= 32 ? trimmed : trimmed.substring(0, 32);
  }

  HeartRateReport _report(Map<String, Object?> json) => HeartRateReport(
    memberId: json['memberId'] as String,
    displayName: _displayName(json['displayName']),
    bpm: json['bpm'] as int,
    rrIntervalsMs: (json['rrMs'] as List).cast<int>(),
    sensorContact: json['sensorContact'] as bool?,
    sequence: json['sequence'] as int,
    measuredAt: DateTime.parse(json['measuredAt'] as String).toUtc(),
  );

  void _broadcast(RoomMessageType type, Map<String, Object?> data) {
    final text = jsonEncode(RoomEnvelope(type: type, data: data).toJson());
    for (final socket in List<WebSocket>.from(_sockets.values)) {
      socket.add(text);
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _pruneTimer?.cancel();
    _snapshotTimer?.cancel();
    for (final socket in _sockets.values) {
      await socket.close(WebSocketStatus.normalClosure, 'Relay stopped');
    }
    _sockets.clear();
    await _server?.close(force: true);
    await store.dispose();
    _log.info('relay', 'Relay stopped');
  }
}
