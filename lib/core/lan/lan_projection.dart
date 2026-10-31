import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../profile/install_identity.dart';
import '../../room/protocol.dart';
import '../../room/room_code.dart';
import 'lan_projection_server.dart';

/// 「投射到局域网」的开关与状态（手机侧）。
///
/// 默认开启：PC 端没有蓝牙时靠它拿数据。开启时在手机里起一个内网 WS 服务
/// （[LanProjectionServer]），关掉立刻停服务、停广播、断开所有客户端。
final class LanProjection extends ChangeNotifier {
  LanProjection({LanProjectionServer? server, this.store, AppLogger? logger})
    : _server = server ?? LanProjectionServer(logger: logger),
      _log = logger ?? AppLogger.instance;

  static const enabledKey = 'lan.enabled';
  static const roomKey = 'lan.room';

  final LanProjectionServer _server;
  final IdentityStore? store;
  final AppLogger _log;

  bool _enabled = true;
  bool _starting = false;
  String _code = '';
  String _name = '';

  bool get enabled => _enabled;
  bool get running => _server.isRunning;
  bool get starting => _starting;
  int get port => _server.portInUse;
  int get connections => _server.connectionCount;
  int get members => _server.memberCount;
  String get code => _code;
  String get displayCode => _code.isEmpty ? '----' : _code;

  /// 启动/停止一次（幂等）。房间码缺省时用与中继同一套规则生成并持久化。
  Future<void> apply({String? roomCode, String? displayName}) async {
    if (roomCode != null && roomCode.isNotEmpty) _code = roomCode;
    if (displayName != null && displayName.isNotEmpty) _name = displayName;
    if (_code.isEmpty) {
      _code = RoomCode.generate();
      await _persistRoom();
    }
    if (!_enabled) {
      await _server.stop();
      notifyListeners();
      return;
    }
    if (_server.isRunning) {
      notifyListeners();
      return;
    }
    _starting = true;
    notifyListeners();
    final ok = await _server.start(room: _code, name: _name);
    _starting = false;
    if (!ok) {
      _log.warn('lan', 'projection failed to start', code: 'lan_start_failed');
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      await store?.saveLanEnabled(value);
    } catch (error, stack) {
      _log.error(
        'lan',
        'save projection preference failed',
        null,
        error,
        stack,
      );
    }
    if (value) {
      await apply();
    } else {
      await _server.stop();
      notifyListeners();
    }
  }

  /// 广播里用的设备名（昵称），PC 列表直接显示。
  String get deviceName => _name.isEmpty ? 'Android' : _name;

  /// 手机自己的每次采样（1 Hz）都推给局域网客户端。
  void publishOwnSample({
    required String memberId,
    required String name,
    required int bpm,
    required List<int> rrMs,
    required bool? sensorContact,
    required int sequence,
    required DateTime measuredAt,
  }) {
    if (!_server.isRunning) return;
    _server.publishOwnSample(
      memberId: memberId,
      name: name,
      bpm: bpm,
      rrMs: rrMs,
      sensorContact: sensorContact,
      sequence: sequence,
      measuredAt: measuredAt,
    );
  }

  /// 云端房间里其他成员的变化转给局域网客户端（PC 能看到整个房间）。
  void publishRoomMembers(Iterable<MemberState> members) {
    if (!_server.isRunning) return;
    _server.publishRoomMembers(members);
  }

  /// 启动时从本地恢复偏好；默认开启。
  Future<void> restore() async {
    final identity = store;
    if (identity == null) return;
    try {
      _enabled = await identity.loadLanEnabled();
      _code = await identity.loadLanRoom() ?? '';
    } catch (error, stack) {
      _log.error(
        'lan',
        'restore projection preference failed',
        null,
        error,
        stack,
      );
    }
    notifyListeners();
  }

  Future<void> _persistRoom() async {
    try {
      await store?.saveLanRoom(_code);
    } catch (error, stack) {
      _log.error('lan', 'save projection room failed', null, error, stack);
    }
  }

  @override
  void dispose() {
    unawaited(_server.stop());
    super.dispose();
  }
}
