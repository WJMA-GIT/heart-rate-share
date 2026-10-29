import 'ble_models.dart';

/// 扫描收尾时该往 snapshot 上写什么 phase（null = 什么都不写）。
///
/// 为什么会需要这个判断：`startScan` 在 `await Future.delayed(timeout)` 之后
/// 才收尾，而用户完全可能在扫描还没结束时点「连接」。旧实现收尾时无条件
/// `phase = idle`，于是扫描超时的那一刻把已经建立的 `subscribed` 覆写掉，
/// 界面显示"空闲"，而链路和心率通知其实都还活着。
///
/// 2026-10-29 的现场日志就是这个路径：11:18:46.598 开始第二轮扫描，
/// 11:18:49.490 用户点连接并订阅成功，11:18:56.602（扫描起点 + 10.004 秒、
/// 正好是 `timeout`）跳出一条 `phase=idle`，此后 22 分钟 phase 一直是 idle，
/// 但每秒仍有一次 snapshot —— 那是心率通知还在送。
BleConnectionPhase? scanTailPhase({
  required bool superseded,
  required bool linkIsUp,
}) {
  // 这一轮扫描已经被新的扫描或连接流程接管：不许改动 phase。
  if (superseded) return null;
  // 链路活着时收尾只可能发生在"扫描期间顺手连上了"，保持 subscribed。
  return linkIsUp ? BleConnectionPhase.subscribed : BleConnectionPhase.idle;
}
