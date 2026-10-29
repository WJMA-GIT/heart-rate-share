import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/logging/app_logger.dart';

void main() {
  test('redacts credential-looking fields and shortens device ID', () {
    final result = LogSanitizer.text('token=abc authorization: Bearer-value');
    expect(result, isNot(contains('abc')));
    expect(result, isNot(contains('Bearer-value')));
    // 实现固定保留末 8 个字符（3 段，如 DD:EE:FF），而不是 4 段：
    // 段数越少暴露越少，且 OUI 前缀本来就不该出现在日志里。
    // 原断言写成 4 段（…CC:DD:EE:FF）与实现不符，且方向是暴露更多，故修测试。
    expect(LogSanitizer.device('AA:BB:CC:DD:EE:FF'), '…DD:EE:FF');
  });
}
