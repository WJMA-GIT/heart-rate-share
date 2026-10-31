/// 版本号连点闸门：默认 5 次、相邻两次间隔不超过 3 秒，超时就从 1 重新数。
///
/// 设置为的是"删掉显式的调试入口，但不彻底断掉排障路径"：连点版本号才进诊断，
/// 误触/手抖不会打开日志面板。
final class VersionTapGate {
  VersionTapGate({
    this.required = 5,
    this.window = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int required;
  final Duration window;
  final DateTime Function() _clock;

  int _count = 0;
  DateTime? _last;

  /// 当前累计次数（用于界面提示/测试）。
  int get count => _count;

  /// 记一次点击；累计到 [required] 时返回 true 并清零。
  bool tap() {
    final now = _clock();
    final last = _last;
    final delta = last == null ? null : now.difference(last);
    // 时钟回拨（负差值）或超过窗口都从 1 重新数。
    if (delta == null || delta.isNegative || delta > window) {
      _count = 1;
    } else {
      _count++;
    }
    _last = now;
    if (_count >= required) {
      reset();
      return true;
    }
    return false;
  }

  void reset() {
    _count = 0;
    _last = null;
  }
}
