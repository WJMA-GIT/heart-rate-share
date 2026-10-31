import 'dart:async';

import '../core/logging/app_logger.dart';
import '../core/profile/install_identity.dart';

/// 跨启动单调递增的上报序号。
///
/// 为什么需要：服务端（`server/src/relay.js`）对同一
/// memberId 只接受**严格递增**的 sequence，否则当旧包丢弃。身份一旦稳定，
/// App 重启后如果序号从 1 重来，服务端会一直丢包 —— 成员看着在线却没有数据，
/// 直到客户端把序号追过上一个进程的值。所以序号也必须持久化。
///
/// 持久化策略是「预留区块」：只在用到预留上界时写一次盘（默认 60 个一块，
/// 1 Hz 上报下约每分钟一次），进程被强杀最多浪费一个区块，绝不会回退。
final class SequenceCounter {
  SequenceCounter._(this._store, this._value, this._reservedUpTo, this._log);

  /// 从本地恢复；失败时退化为从 0 开始（只影响极少数被丢弃的旧包）。
  static Future<SequenceCounter> restore(
    IdentityStore store, {
    int block = 60,
    AppLogger? logger,
  }) async {
    final log = logger ?? AppLogger.instance;
    var reserved = 0;
    try {
      reserved = await store.loadReservedSequence();
    } catch (error, stack) {
      log.error('room', 'sequence restore failed', null, error, stack);
    }
    final counter = SequenceCounter._(store, reserved, reserved, log);
    counter._block = block;
    // 立刻用掉一个区块，保证"启动后立刻被杀"也不会重号。
    await counter._reserveMore();
    return counter;
  }

  final IdentityStore _store;
  final AppLogger _log;
  int _value;
  int _reservedUpTo;
  int _block = 60;

  int get value => _value;

  /// 预留到哪个上界（仅用于诊断显示）。
  int get reservedUpTo => _reservedUpTo;

  /// 取下一个序号。同步、不阻塞上报路径。
  int next() {
    _value += 1;
    if (_value > _reservedUpTo) {
      _reservedUpTo = _value + _block;
      unawaited(_persist(_reservedUpTo));
    }
    return _value;
  }

  /// 从服务端快照里看到自己的序号更大时抬升本地值。
  ///
  /// 覆盖两种脏情况：本地序号存储被清掉（部分清数据）、或从旧备份恢复。
  /// 抬升不会回退，因此只会多写一次盘。
  ///
  /// 服务端会把我们自己上报的序号原样回显进快照：`observed == _value` 不是抬升，
  /// 再抬就等于每秒写一条假告警（真机日志里 79% 都是这种噪声）。
  void bumpAbove(int observed) {
    if (observed <= _value) return;
    _value = observed;
    _log.info(
      'room',
      'sequence raised to server value=$observed',
      code: 'sequence_raised',
    );
    if (_value > _reservedUpTo) {
      _reservedUpTo = _value + _block;
      unawaited(_persist(_reservedUpTo));
    }
  }

  Future<void> _reserveMore() async {
    _reservedUpTo = _value + _block;
    await _persist(_reservedUpTo);
  }

  Future<void> _persist(int reservedUpTo) async {
    try {
      await _store.saveReservedSequence(reservedUpTo);
    } catch (error, stack) {
      // 写盘失败不能影响上报；最坏情况是重启后重号，服务端丢几包。
      _log.error('room', 'sequence persist failed', null, error, stack);
    }
  }

  /// 退出前落盘：把当前预留上界再写一遍，确保最后一次异步写已完成。
  Future<void> flush() => _persist(_reservedUpTo);
}
