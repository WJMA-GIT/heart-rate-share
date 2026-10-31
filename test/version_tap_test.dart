import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ui/version_tap.dart';

void main() {
  test('5 次连点（相邻间隔 3 秒内）才触发，触发后清零', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final gate = VersionTapGate(clock: () => now);

    for (var i = 0; i < 4; i++) {
      expect(gate.tap(), isFalse, reason: '第 ${i + 1} 次还不该触发');
      now = now.add(const Duration(milliseconds: 400));
    }
    expect(gate.count, 4);
    expect(gate.tap(), isTrue);
    expect(gate.count, 0, reason: '触发后重新计数');
    expect(gate.tap(), isFalse);
  });

  test('窗口过期就重置：断一次之后要重新数满 5 次', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final gate = VersionTapGate(clock: () => now);

    expect(gate.tap(), isFalse);
    expect(gate.tap(), isFalse);
    expect(gate.count, 2);

    now = now.add(const Duration(seconds: 4));
    expect(gate.tap(), isFalse);
    expect(gate.count, 1, reason: '超过 3 秒重新从 1 开始');

    now = now.add(const Duration(seconds: 1));
    expect(gate.tap(), isFalse);
    expect(gate.tap(), isFalse);
    expect(gate.tap(), isFalse);
    expect(gate.tap(), isTrue, reason: '连续 5 次（1+4）才触发');
  });

  test('系统时钟回拨不算连续点击', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final gate = VersionTapGate(clock: () => now);
    expect(gate.tap(), isFalse);
    expect(gate.tap(), isFalse);
    expect(gate.count, 2);
    now = now.subtract(const Duration(seconds: 10));
    expect(gate.tap(), isFalse);
    expect(gate.count, 1);
  });

  test('恰好 3 秒间隔仍算连续（边界不误伤）', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final gate = VersionTapGate(clock: () => now);
    var fired = false;
    for (var i = 0; i < 5; i++) {
      if (gate.tap()) fired = true;
      now = now.add(const Duration(seconds: 3));
    }
    expect(fired, isTrue);
  });
}
