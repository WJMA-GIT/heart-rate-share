import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// 悬浮窗里的一行：名称 + 实时 BPM + 该成员最近的心率折线（离线时都没有）。
///
/// [points] 是**归一化**折线（x/y 都在 0..1，y=0 在顶部），由首页同一个
/// `normalizedPolyline` 算出；原生侧只把点缩放到小矩形里画，不自己算窗口/量程。
/// [bridges] 是短缺测的过渡线（每项 `[x0,y0,x1,y1]`），原生侧画成淡色虚线。
/// 关闭「显示折线图」时两者都为空 = 原生侧不画、也不占宽度。
final class OverlayMember {
  const OverlayMember({
    required this.name,
    this.bpm,
    required this.online,
    this.points = const [],
    this.bridges = const [],
  });

  final String name;
  final int? bpm;
  final bool online;
  final List<List<double>> points;
  final List<List<double>> bridges;

  Map<String, Object?> toChannel() => {
    'name': name,
    'bpm': bpm,
    'online': online,
    'points': points,
    'bridges': bridges,
  };
}

/// 悬浮窗的两个不透明度维度：
/// - [minAlpha]/[defaultAlpha] 管**背景**（0 = 完全透明，只剩文字与折线）；
/// - [contentAlpha] 管**内容**，固定 100%，不跟滑块走。原生侧只把背景不透明度
///   写进背景 drawable，从不设置 `view.alpha`。
abstract final class OverlayDefaults {
  /// 0 = 背景全透明。旧版下限 0.35 已放开，旧持久化值按背景不透明度直接生效。
  static const minAlpha = 0.0;
  static const defaultAlpha = 0.85;
  static const contentAlpha = 1.0;

  /// 「显示折线图」默认开。
  static const defaultShowChart = true;
}

/// 系统悬浮窗的平台桥（可替换，便于单测）。
abstract interface class RoomOverlayBackend {
  /// 当前是否已授予 `SYSTEM_ALERT_WINDOW`（只查，不弹窗）。
  Future<bool> isPermissionGranted();

  /// 打开系统授权页（只在用户主动开启时调用，不自动骚扰）。
  Future<bool> requestPermission();

  /// [alpha] 是**背景**不透明度（0..1）；内容始终不透明。
  Future<bool> show(List<OverlayMember> members, double alpha);
  Future<bool> update(List<OverlayMember> members);
  Future<bool> setAlpha(double alpha);
  Future<bool> hide();
}

/// Android 实现：复用现有 `MethodChannel` 风格，不引入任何依赖。
///
/// 窗口本身在原生侧（前台保活服务里挂一个 `TYPE_APPLICATION_OVERLAY` 视图），
/// Dart 只负责把成员列表与背景不透明度推下去；没有房间连接时原生侧不会显示窗口。
final class PlatformRoomOverlay implements RoomOverlayBackend {
  const PlatformRoomOverlay();

  static const channel = MethodChannel('com.wjmagit.heartrateshare/overlay');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!supported) return null;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      // 原生只在真出问题时回 error（例如拖动时 updateViewLayout 抛异常）。
      // 每种方法只记一次：同一个错每秒重试一次，不能把会话日志刷满。
      if (_reportedErrors.add(method)) {
        AppLogger.instance.warn(
          'overlay',
          'overlay channel $method failed: ${error.message}',
          code: 'overlay_channel_error',
        );
      }
      return null;
    }
  }

  static final Set<String> _reportedErrors = {};

  @override
  Future<bool> isPermissionGranted() async =>
      await _invoke<bool>('permissionState') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _invoke<bool>('requestPermission') ?? false;

  @override
  Future<bool> show(List<OverlayMember> members, double alpha) async =>
      await _invoke<bool>('show', {
        'members': [for (final member in members) member.toChannel()],
        'alpha': alpha.clamp(OverlayDefaults.minAlpha, 1.0),
      }) ??
      false;

  @override
  Future<bool> update(List<OverlayMember> members) async =>
      await _invoke<bool>('update', {
        'members': [for (final member in members) member.toChannel()],
      }) ??
      false;

  @override
  Future<bool> setAlpha(double alpha) async =>
      await _invoke<bool>('alpha', {
        'alpha': alpha.clamp(OverlayDefaults.minAlpha, 1.0),
      }) ??
      false;

  @override
  Future<bool> hide() async => await _invoke<bool>('hide') ?? false;
}
