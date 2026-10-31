import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/logging/app_logger.dart';
import 'package:heartrate/core/profile/install_identity.dart';
import 'package:heartrate/room/sequence_counter.dart';

void main() {
  group('InstallId', () {
    test('生成 UUID v4 形状且每次不同', () {
      final a = InstallId.generate();
      final b = InstallId.generate();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
        reason: a,
      );
      expect(a, isNot(b));
    });

    test('只接受服务端 memberId 能用的短字符串', () {
      expect(InstallId.isValid(InstallId.generate()), isTrue);
      expect(InstallId.isValid(null), isFalse);
      expect(InstallId.isValid(''), isFalse);
      expect(InstallId.isValid('short'), isFalse);
      expect(InstallId.isValid('has space and 中文'), isFalse);
      expect(InstallId.isValid('a' * 129), isFalse);
    });
  });

  group('IdentityStore 持久化语义', () {
    test('首次启动写入后，重启读回同一个安装标识', () async {
      final store = InMemoryIdentityStore();
      final first = await store.loadInstallId();
      expect(first, isNull);
      final created = InstallId.generate();
      await store.saveInstallId(created);

      // 模拟进程重启：同一个 store（磁盘），新的启动流程。
      final reloaded = await store.loadInstallId();
      expect(reloaded, created);
    });

    test('清数据/重装 = 新标识（new 成员，而不是旧成员复活）', () async {
      final oldStore = InMemoryIdentityStore();
      await oldStore.saveInstallId(InstallId.generate());
      final oldId = await oldStore.loadInstallId();

      final freshStore = InMemoryIdentityStore(); // 数据被清空
      expect(await freshStore.loadInstallId(), isNull);
      final newId = InstallId.generate();
      await freshStore.saveInstallId(newId);
      expect(newId, isNot(oldId));
    });
  });

  group('SequenceCounter', () {
    test('重启后从预留上界继续，绝不回退', () async {
      final store = InMemoryIdentityStore();
      final first = await SequenceCounter.restore(store, block: 10);
      expect(first.value, 0);
      expect(store.reservedSequence, 10, reason: '启动即预留一个区块');

      final used = [for (var i = 0; i < 5; i++) first.next()];
      expect(used, [1, 2, 3, 4, 5]);
      expect(store.reservedSequence, 10, reason: '区块内不写盘');

      // 进程被杀后重启
      final second = await SequenceCounter.restore(store, block: 10);
      expect(second.value, 10);
      expect(second.next(), 11);
    });

    test('跨过预留上界会立刻抬高持久化值', () async {
      final store = InMemoryIdentityStore();
      final counter = await SequenceCounter.restore(store, block: 2);
      final start = counter.value;
      for (var i = 0; i < 5; i++) {
        counter.next();
      }
      await Future<void>.delayed(Duration.zero);
      expect(store.reservedSequence >= counter.value, isTrue);
      expect(store.reservedSequence > start, isTrue);
    });

    test('看到服务端上更大的序号时抬升，且不回退', () async {
      final store = InMemoryIdentityStore();
      final counter = await SequenceCounter.restore(store, block: 10);
      counter.bumpAbove(500);
      expect(counter.next(), 501);
      counter.bumpAbove(1);
      expect(counter.next(), 502);
    });

    test('服务端回显自己的序号不算抬升，也不写日志', () async {
      final counter = await SequenceCounter.restore(
        InMemoryIdentityStore(),
        block: 10,
      );
      final used = counter.next();
      final before = AppLogger.instance.entries.length;

      counter.bumpAbove(used); // 快照里回显的就是我们刚上报的序号
      expect(
        AppLogger.instance.entries.length,
        before,
        reason: '回显不是抬升，不能每秒写一条 sequence_raised',
      );
      expect(counter.next(), used + 1);

      counter.bumpAbove(used + 100); // 真·服务端比本地大（清数据/旧备份）
      expect(
        AppLogger.instance.entries
            .skip(before)
            .where((entry) => entry.errorCode == 'sequence_raised'),
        hasLength(1),
      );
      expect(counter.next(), used + 101);
    });

    test('flush 落盘预留上界', () async {
      final store = InMemoryIdentityStore();
      final counter = await SequenceCounter.restore(store, block: 5);
      counter.next();
      await counter.flush();
      expect(store.reservedSequence >= counter.value, isTrue);
    });
  });
}
