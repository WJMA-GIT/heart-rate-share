/// 语义化版本号（只做比较，不引入 package:pub_semver）。
///
/// 为什么要自己写：GitHub 的 tag 是 `v1.0.1`，本地 versionName 是 `1.0.1`，而
/// **字符串比较会把 `1.0.9` 判成比 `1.0.17` 新**（'9' > '1'），直接把更新提示弄错。
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.parts);

  /// 逐段解析：去掉前缀 `v`/`V`、去掉 `+build` 元数据与 `-pre` 后缀，只留数字段。
  /// 解析不出来（空串、全非数字）抛 [FormatException]，调用方按"无法判断"处理。
  factory AppVersion.parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) throw FormatException('empty version', raw);
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    final dash = text.indexOf('-');
    if (dash >= 0) text = text.substring(0, dash);
    final segments = text.split('.');
    final parts = <int>[];
    for (final segment in segments) {
      final match = RegExp(r'^\d+').firstMatch(segment);
      if (match == null) throw FormatException('bad version segment', raw);
      parts.add(int.parse(match.group(0)!));
    }
    if (parts.isEmpty) throw FormatException('bad version', raw);
    return AppVersion(parts);
  }

  final List<int> parts;

  @override
  int compareTo(AppVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var index = 0; index < length; index++) {
      final a = index < parts.length ? parts[index] : 0;
      final b = index < other.parts.length ? other.parts[index] : 0;
      if (a != b) return a < b ? -1 : 1;
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => parts.join('.');
}

/// 比较两个版本字符串：[remote] 是否比 [local] 新。解析失败时返回 null（不知道）。
bool? isRemoteNewer(String local, String remote) {
  try {
    return AppVersion.parse(remote) > AppVersion.parse(local);
  } on FormatException {
    return null;
  }
}
