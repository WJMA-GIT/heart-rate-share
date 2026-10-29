import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/reconnect_policy.dart';
import 'package:heartrate/core/config/app_config.dart';

void main() {
  test('退避等待按尝试次数线性增长并在上限封顶', () {
    const policy = ReconnectPolicy();
    final delays = [
      for (var attempt = 0; attempt < 6; attempt++)
        policy.delayFor(attempt)!.inMilliseconds,
    ];
    expect(delays, [500, 1000, 1500, 2000, 2000, 2000]);
  });

  test('重连配额用尽后不再给出等待', () {
    const policy = ReconnectPolicy(maxAttempts: 2);
    expect(policy.delayFor(0), isNotNull);
    expect(policy.delayFor(1), isNotNull);
    expect(policy.delayFor(2), isNull);
    expect(policy.delayFor(-1), isNull);
  });

  test('自定义参数生效', () {
    const policy = ReconnectPolicy(
      maxAttempts: 1,
      baseDelay: Duration(milliseconds: 100),
      maxDelay: Duration(milliseconds: 150),
    );
    expect(policy.delayFor(0)!.inMilliseconds, 100);
    expect(policy.delayFor(1), isNull);
  });

  test('单次退避必须显著短于 Relay 的离线判定窗口', () {
    const policy = ReconnectPolicy();
    expect(
      policy.maxDelay < AppConfig.offlineAfter,
      isTrue,
      reason: '退避上限不能把「BLE 抖动」放大成「房间成员离线」',
    );
  });
}
