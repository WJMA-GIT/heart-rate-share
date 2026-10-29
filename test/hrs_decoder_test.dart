import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/heart_rate_sample.dart';

void main() {
  const decoder = HrsDecoder();
  final at = DateTime.utc(2026, 1, 1);

  test('decodes 8-bit BPM and multiple RR intervals', () {
    final sample = decoder.decode([0x16, 72, 0x00, 0x04, 0x80, 0x03], receivedAt: at);
    expect(sample.bpm, 72);
    expect(sample.sensorContact, isTrue);
    expect(sample.rrIntervalsMs, [1000, 875]);
    expect(sample.receivedAt, at);
  });

  test('decodes 16-bit BPM, no contact, and skips energy', () {
    final sample = decoder.decode([0x09, 0x2c, 0x01, 0x10, 0x00], receivedAt: at);
    expect(sample.bpm, 300);
    expect(sample.sensorContact, isNull);
    expect(sample.rrIntervalsMs, isEmpty);
  });

  test('rejects empty, truncated, and reserved flag data', () {
    expect(() => decoder.decode([]), throwsA(isA<HrsFormatException>()));
    expect(() => decoder.decode([1, 1]), throwsA(isA<HrsFormatException>()));
    expect(() => decoder.decode([0x20, 70]), throwsA(isA<HrsFormatException>()));
  });
}
