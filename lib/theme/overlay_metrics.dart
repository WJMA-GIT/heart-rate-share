/// 悬浮窗（手机原生 + Windows 紧凑态）的**唯一**列宽/尺寸来源。
///
/// 手机悬浮窗是原生 View（`android/app/src/main/kotlin/.../BleKeepAliveService.kt`），
/// 没法直接 import Dart 常量，所以那份 Kotlin 里的同名常量由
/// `test/overlay_metrics_test.dart` 在 CI 里逐项比对——两份一旦不一致测试就红，
/// 不存在"各写一份、慢慢漂移"。
abstract final class OverlayMetrics {
  /// 名称列固定宽：超出省略号（tooltip 看全名）。
  static const nameWidth = 96.0;

  /// 心率列固定宽 + 右对齐：位数变化不影响折线位置。
  static const bpmWidth = 48.0;

  /// 迷你折线列固定宽/高。
  static const chartWidth = 72.0;
  static const chartHeight = 20.0;

  /// 单行高度（紧凑态）：行高 = 这个值 × 缩放。
  static const rowHeight = 22.0;

  /// 有多人时窗口最大高度，超出内部滚动（不无限长高）。
  static const maxListHeight = 220.0;
}
