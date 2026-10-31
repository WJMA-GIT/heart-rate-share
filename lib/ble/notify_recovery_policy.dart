/// notify 链路"断了但没断干净"时该怎么办。
///
/// 两种情形必须分开处理：
/// - 设备还在（`isConnected == true`）但通知停了：常见于 Android 的 Services
///   Changed（0x2A05）导致的 CCCD 失效、或 notify 流异常关闭。此时整条链路
///   重建代价大、空窗长，正确做法是**重新订阅特征**。
/// - 设备已经不在：只能走整条重连（带退避）。
///
/// 但重订阅不能无限循环 —— 带子反复重置服务时，无上限重订阅会变成忙等。
/// 所以窗口内超过 [NotifyRecoveryPolicy.maxAttempts] 次就升级为整条重连。
enum NotifyRecoveryAction {
  /// 设备还在，重新 discover + setNotifyValue。
  resubscribe,

  /// 交给重连监督器（带退避）。
  reconnect,
}

final class NotifyRecoveryPolicy {
  const NotifyRecoveryPolicy({
    this.maxAttempts = 2,
    this.window = const Duration(seconds: 30),
  });

  /// 一个 [window] 内允许的重订阅次数，超过就升级为整条重连。
  final int maxAttempts;

  /// 计数窗口。
  final Duration window;

  NotifyRecoveryAction actionFor({
    required bool deviceConnected,
    required int attemptsInWindow,
  }) {
    if (!deviceConnected) return NotifyRecoveryAction.reconnect;
    if (attemptsInWindow >= maxAttempts) {
      return NotifyRecoveryAction.reconnect;
    }
    return NotifyRecoveryAction.resubscribe;
  }
}
