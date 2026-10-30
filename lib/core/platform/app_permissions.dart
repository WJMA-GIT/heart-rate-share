import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 启动时要用的权限状态。键与 Android 侧 `permissionState()` 一致。
final class PermissionState {
  const PermissionState({required this.notifications, required this.bluetooth});

  const PermissionState.allGranted() : notifications = true, bluetooth = true;

  final bool notifications;
  final bool bluetooth;

  bool get allGranted => notifications && bluetooth;
}

/// 权限申请（Android）。走已有的 foreground 通道，不额外引依赖。
///
/// 拒绝不是错误：只影响能力（通知 → 后台保活可见性；蓝牙 → 扫描心率带），
/// 由界面给出降级说明与「去设置」入口，不静默失败也不反复弹。
final class AppPermissions {
  static const _channel = MethodChannel(
    'com.wjmagit.heartrateshare/foreground',
  );

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<PermissionState> request() async {
    if (!_supported) return const PermissionState.allGranted();
    try {
      final result = await _channel.invokeMapMethod<String, bool>(
        'permissions',
      );
      return PermissionState(
        notifications: result?['notifications'] ?? false,
        bluetooth: result?['bluetooth'] ?? false,
      );
    } catch (_) {
      // 通道不可用（例如桌面端）时按已授权处理，不挡启动。
      return const PermissionState.allGranted();
    }
  }

  /// 只读当前状态，不触发系统对话框。
  static Future<PermissionState> check() async {
    if (!_supported) return const PermissionState.allGranted();
    try {
      final result = await _channel.invokeMapMethod<String, bool>(
        'permissionState',
      );
      return PermissionState(
        notifications: result?['notifications'] ?? false,
        bluetooth: result?['bluetooth'] ?? false,
      );
    } catch (_) {
      return const PermissionState.allGranted();
    }
  }

  /// 打开本应用的系统设置页（用户拒绝后唯一的补救入口）。
  static Future<bool> openAppSettings() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('appSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
