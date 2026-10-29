import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/notify_recovery_policy.dart';

void main() {
  group('NotifyRecoveryPolicy', () {
    const policy = NotifyRecoveryPolicy(maxAttempts: 2);

    test('设备已经不在：直接交给整条重连', () {
      expect(
        policy.actionFor(deviceConnected: false, attemptsInWindow: 0),
        NotifyRecoveryAction.reconnect,
      );
    });

    test('设备还在：先原地重订阅', () {
      expect(
        policy.actionFor(deviceConnected: true, attemptsInWindow: 0),
        NotifyRecoveryAction.resubscribe,
      );
      expect(
        policy.actionFor(deviceConnected: true, attemptsInWindow: 1),
        NotifyRecoveryAction.resubscribe,
      );
    });

    test('窗口内重订阅次数用尽就升级为整条重连，避免忙等', () {
      expect(
        policy.actionFor(deviceConnected: true, attemptsInWindow: 2),
        NotifyRecoveryAction.reconnect,
      );
      expect(
        policy.actionFor(deviceConnected: true, attemptsInWindow: 5),
        NotifyRecoveryAction.reconnect,
      );
    });

    test('自定义预算生效', () {
      const strict = NotifyRecoveryPolicy(maxAttempts: 1);
      expect(
        strict.actionFor(deviceConnected: true, attemptsInWindow: 0),
        NotifyRecoveryAction.resubscribe,
      );
      expect(
        strict.actionFor(deviceConnected: true, attemptsInWindow: 1),
        NotifyRecoveryAction.reconnect,
      );
      expect(strict.window, const Duration(seconds: 30));
    });
  });
}
