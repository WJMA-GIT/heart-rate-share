import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ble/platform/hrs_foreground.dart';
import '../logging/app_logger.dart';

/// 前台服务的底层实现（可替换，便于单测）。
abstract interface class ForegroundBackend {
  Future<bool> start();
  Future<bool> stop();
}

final class HrsForegroundBackend implements ForegroundBackend {
  const HrsForegroundBackend();

  @override
  Future<bool> start() => HrsForeground.start();

  @override
  Future<bool> stop() => HrsForeground.stop();
}

/// 前台服务的「租约」。
///
/// 为什么需要：0.3.3 加的前台服务只在 **BLE 已连接**时启动（`connectedDevice`
/// 类型），房间 WebSocket 完全没有保护。而 App 切到后台后，没有前台服务的进程
/// 会被系统冻结/降级，socket 不再收发 —— 于是"退到后台房间就断"。
///
/// 现在改成引用计数：谁需要保活就 [acquire]（`ble` / `room`），最后一个释放
/// 才真正停止服务。这样 BLE 与房间连接互不干扰，也不会出现"BLE 断开把房间
/// 连接的保活一起关掉"。
final class ForegroundLease {
  ForegroundLease({ForegroundBackend? backend, AppLogger? logger})
    : _backend = backend ?? const HrsForegroundBackend(),
      _log = logger ?? AppLogger.instance;

  static ForegroundLease? _instance;

  /// 进程级默认租约：`HeartRateService` 与 `RoomClient` 共用同一个。
  static ForegroundLease get instance => _instance ??= ForegroundLease();

  final ForegroundBackend _backend;
  final AppLogger _log;
  final Set<String> _holders = {};
  Future<void> _queue = Future<void>.value();
  bool _running = false;

  /// 服务当前是否开着。
  bool get active => _running;

  /// 当前持租约的用途（`ble` / `room`）。
  Set<String> get holders => Set.unmodifiable(_holders);

  /// 申请保活。[reason] 是用途标签，重复申请同一 reason 是幂等的。
  Future<void> acquire(String reason) => _serial(() async {
    if (!_holders.add(reason)) return;
    if (_running) {
      _log.info(
        'app',
        'foreground service already running holders=${_holders.join('+')}',
        code: 'fg_held',
      );
      return;
    }
    _running = await _backend.start();
    _log.info(
      'app',
      'foreground service start=$_running reason=$reason '
          'holders=${_holders.join('+')}',
      code: _running ? 'fg_started' : 'fg_unavailable',
    );
  });

  /// 释放保活。只有最后一个持有者释放时才真正停止服务。
  Future<void> release(String reason) => _serial(() async {
    if (!_holders.remove(reason)) return;
    if (_holders.isNotEmpty) {
      _log.info(
        'app',
        'foreground service kept reason=$reason '
            'holders=${_holders.join('+')}',
        code: 'fg_kept',
      );
      return;
    }
    if (!_running) return;
    _running = false;
    final stopped = await _backend.stop();
    _log.info(
      'app',
      'foreground service stop=$stopped reason=$reason',
      code: stopped ? 'fg_stopped' : 'fg_unavailable',
    );
  });

  /// 串行化 acquire/release，避免并发下重复启动/停止。
  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object _) {});
    return next;
  }

  /// 仅测试用：把租约恢复成初始状态。
  @visibleForTesting
  Future<void> reset() => _serial(() async {
    _holders.clear();
    if (_running) {
      _running = false;
      await _backend.stop();
    }
  });
}
