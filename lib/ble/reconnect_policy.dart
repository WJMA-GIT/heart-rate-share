import '../core/config/app_config.dart';

/// 断连重连的退避策略，纯计算，便于单测。
///
/// 设计约束：Relay 用「[AppConfig.offlineAfter] 内没有心率上报」判定成员
/// 离线（见 `server/src/relay.js` 的 prune），而心率上报只能由 BLE 通知驱动。所以一次
/// 掉线期间「重连尝试 + 退避等待」必须尽量压在这个窗口内，否则房间里的人
/// 会看到自己因为一次 BLE 抖动而离线。
///
/// 因此退避上限取 [AppConfig.offlineAfter] 的一小部分：等待 0.5s、1s、1.5s、
/// 2s 后封顶 2s。常见场景（心率带短暂丢包/系统挂起 GATT）一次尝试就能接回，
/// 总空窗 < 5s，房间状态不翻转。
final class ReconnectPolicy {
  const ReconnectPolicy({
    this.maxAttempts = 12,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 2),
  });

  /// 连续失败多少次后放弃并进入 [BleReconnectOutcome.exhausted]。
  final int maxAttempts;

  /// 第一次重连前的等待，之后按尝试次数线性增长。
  final Duration baseDelay;

  /// 单次等待上限，必须显著小于 Relay 的离线窗口。
  final Duration maxDelay;

  /// 第 [attempt] 次（从 0 起）重连前的等待；已用尽次数时返回 null。
  Duration? delayFor(int attempt) {
    if (attempt < 0 || attempt >= maxAttempts) return null;
    final linear = baseDelay.inMilliseconds * (attempt + 1);
    final capped = linear < maxDelay.inMilliseconds
        ? linear
        : maxDelay.inMilliseconds;
    return Duration(milliseconds: capped);
  }
}

enum BleReconnectOutcome {
  /// 还有下一次重连配额。
  retry,

  /// 配额用尽，需要用户手动重连。
  exhausted,
}
