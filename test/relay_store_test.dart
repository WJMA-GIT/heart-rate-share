import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/room/relay_store.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);
  late RelayStore store;
  setUp(() => store = RelayStore(clock: () => now));
  tearDown(() => store.dispose());

  HeartRateReport report(int sequence) => HeartRateReport(
        memberId: 'member-1', displayName: 'A', bpm: 70 + sequence,
        rrIntervalsMs: const [], sensorContact: true,
        sequence: sequence, measuredAt: now,
      );

  test('rejects stale sequence and marks member offline', () {
    expect(store.accept(report(2)), isNotNull);
    expect(store.accept(report(1)), isNull);
    now = now.add(const Duration(seconds: 6));
    expect(store.prune().single.online, isFalse);
  });

  test('expires member after two minutes', () {
    store.accept(report(1));
    now = now.add(const Duration(minutes: 2));
    expect(store.prune(), isEmpty);
  });
}
