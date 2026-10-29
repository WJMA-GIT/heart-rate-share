import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/room/protocol.dart';
import 'package:heartrate/room/relay_store.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);
  late RelayStore store;
  setUp(() => store = RelayStore(clock: () => now));
  tearDown(() => store.dispose());

  HeartRateReport report(int sequence) => HeartRateReport(
    memberId: 'member-1',
    displayName: 'A',
    bpm: 70 + sequence,
    rrIntervalsMs: const [],
    sensorContact: true,
    sequence: sequence,
    measuredAt: now,
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

  test('resume 保留心率与序号，只顺延在线成员的 lastSeen', () {
    store.accept(report(42));
    now = now.add(const Duration(seconds: 3));

    final resumed = store.resume('member-1');
    expect(resumed, isNotNull);
    expect(resumed!.report.sequence, 42, reason: '序号必须原样保留');
    expect(resumed.report.bpm, 42 + 70);
    expect(resumed.online, isTrue);
    // lastSeen 已顺延到当前，3 秒后的 prune 不会把成员打成离线
    expect(resumed.lastSeen, now);
  });

  test('resume 不把已离线成员凭空点亮', () {
    store.accept(report(1));
    now = now.add(const Duration(seconds: 6));
    store.prune();
    expect(store.members.single.online, isFalse);

    final resumed = store.resume('member-1');
    expect(resumed, isNotNull);
    expect(resumed!.online, isFalse, reason: '必须等真实上报才能恢复在线');
  });

  test('resume 未知成员返回 null，不新建成员', () {
    expect(store.resume('nobody'), isNull);
    expect(store.members, isEmpty);
  });
}
