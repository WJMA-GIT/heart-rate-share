import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/platform/foreground_lease.dart';

final class _FakeBackend implements ForegroundBackend {
  int starts = 0;
  int stops = 0;
  bool running = false;
  bool failStart = false;

  @override
  Future<bool> start() async {
    starts += 1;
    if (failStart) return false;
    running = true;
    return true;
  }

  @override
  Future<bool> stop() async {
    stops += 1;
    running = false;
    return true;
  }
}

void main() {
  late _FakeBackend backend;
  late ForegroundLease lease;

  setUp(() {
    backend = _FakeBackend();
    lease = ForegroundLease(backend: backend);
  });

  tearDown(() => lease.reset());

  test('第一个持有者启动服务，最后一个释放才停止', () async {
    await lease.acquire('ble');
    expect(backend.starts, 1);
    expect(lease.active, isTrue);
    expect(lease.holders, {'ble'});

    // BLE 断开但房间还连着 —— 服务必须继续开着
    await lease.acquire('room');
    await lease.release('ble');
    expect(backend.stops, 0, reason: '还有房间连接在用，不能停');
    expect(lease.active, isTrue);
    expect(lease.holders, {'room'});

    await lease.release('room');
    expect(backend.stops, 1);
    expect(lease.active, isFalse);
  });

  test('同一 reason 重复申请/释放是幂等的（不会重复启停）', () async {
    await lease.acquire('room');
    await lease.acquire('room');
    await lease.acquire('room');
    expect(backend.starts, 1);

    await lease.release('room');
    expect(backend.stops, 1);

    // 再次释放不应再停一次
    await lease.release('room');
    expect(backend.stops, 1);
  });

  test('释放从未申请过的 reason 不做任何事', () async {
    await lease.release('room');
    expect(backend.starts, 0);
    expect(backend.stops, 0);
  });

  test('后台拒绝启动时租约保持 inactive，但仍记录持有者', () async {
    backend.failStart = true;
    await lease.acquire('room');
    expect(lease.active, isFalse);
    expect(lease.holders, {'room'});
    // 释放时不调用 stop（本来就没起来）
    await lease.release('room');
    expect(backend.stops, 0);
  });

  test('并发 acquire 只启动一次', () async {
    await Future.wait([
      lease.acquire('ble'),
      lease.acquire('room'),
      lease.acquire('ble'),
    ]);
    expect(backend.starts, 1);
    expect(lease.holders, {'ble', 'room'});
  });
}
