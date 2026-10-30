import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/l10n/strings_zh.dart';
import '../../core/logging/app_logger.dart';
import '../../core/platform/app_permissions.dart';

const _promptedKey = 'permission_prompted';

/// 启动时一次性引导：说清每个权限为什么需要，拒绝后给降级说明与「去设置」。
///
/// 只问一次（"稍后"也算问过），之后由设置页的卡片兜底，避免反复弹窗。
Future<void> ensureStartupPermissions(BuildContext context) async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    // 存不了偏好就退化成"每次都问"是不可接受的，直接不再提示。
  }
  final asked = prefs?.getBool(_promptedKey) ?? false;
  if (asked) {
    final state = await AppPermissions.check();
    AppLogger.instance.info(
      'app',
      'permissions notifications=${state.notifications} '
          'bluetooth=${state.bluetooth}',
      code: 'permission_state',
    );
    return;
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(Zh.permissionTitle),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Zh.permissionNotifications),
          SizedBox(height: 12),
          Text(Zh.permissionBluetooth),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(Zh.permissionLater),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text(Zh.permissionGrant),
        ),
      ],
    ),
  );
  await prefs?.setBool(_promptedKey, true);
  if (go != true) return;

  final state = await AppPermissions.request();
  AppLogger.instance.info(
    'app',
    'permissions requested notifications=${state.notifications} '
        'bluetooth=${state.bluetooth}',
    code: 'permission_result',
  );
  if (state.allGranted || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(Zh.permissionDeniedTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!state.notifications)
            const Text(Zh.permissionDeniedNotifications),
          if (!state.bluetooth) const Text(Zh.permissionDeniedBluetooth),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text(Zh.close),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            AppPermissions.openAppSettings();
          },
          child: const Text(Zh.openAppSettings),
        ),
      ],
    ),
  );
}
