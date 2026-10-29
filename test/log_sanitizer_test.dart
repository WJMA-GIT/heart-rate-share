import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/logging/app_logger.dart';

void main() {
  test('redacts credential-looking fields and shortens device ID', () {
    final result = LogSanitizer.text('token=abc authorization: Bearer-value');
    expect(result, isNot(contains('abc')));
    expect(result, isNot(contains('Bearer-value')));
    expect(LogSanitizer.device('AA:BB:CC:DD:EE:FF'), '…CC:DD:EE:FF');
  });
}
