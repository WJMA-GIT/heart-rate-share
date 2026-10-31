import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/ble/ble_models.dart';
import 'package:heartrate/ble/scan_tail.dart';

void main() {
  group('scanTailPhase', () {
    test('扫描已被连接流程接管时不写 phase', () {
      // 2026-10-29 现场日志的路径：扫描没结束就点了连接。
      expect(scanTailPhase(superseded: true, linkIsUp: true), isNull);
      expect(scanTailPhase(superseded: true, linkIsUp: false), isNull);
    });

    test('扫描期间顺手连上了，收尾不能把 subscribed 打回 idle', () {
      expect(
        scanTailPhase(superseded: false, linkIsUp: true),
        BleConnectionPhase.subscribed,
      );
    });

    test('普通扫描结束回到 idle', () {
      expect(
        scanTailPhase(superseded: false, linkIsUp: false),
        BleConnectionPhase.idle,
      );
    });
  });
}
