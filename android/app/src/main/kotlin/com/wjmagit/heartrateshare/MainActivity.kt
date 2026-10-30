package com.wjmagit.heartrateshare

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// 启动时要申请的权限：按 SDK 分层，低版本用位置权限做兼容写法。
    /// 只声明真正需要的，避免"一次弹一堆看不懂的权限"。
    private fun requiredPermissions(): List<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list += Manifest.permission.POST_NOTIFICATIONS
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list += Manifest.permission.BLUETOOTH_SCAN
            list += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            // Android 11 及以下：扫描 BLE 需要位置权限。
            list += Manifest.permission.ACCESS_FINE_LOCATION
        }
        return list
    }

    private fun isGranted(permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun permissionState(): Map<String, Boolean> {
        val notification =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                isGranted(Manifest.permission.POST_NOTIFICATIONS)
        val bluetooth = requiredPermissions()
            .filter { it != Manifest.permission.POST_NOTIFICATIONS }
            .all { isGranted(it) }
        return mapOf("notifications" to notification, "bluetooth" to bluetooth)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            pendingPermissionResult?.success(permissionState())
            pendingPermissionResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 前台服务开关。Dart 侧（HrsForeground）把失败当非致命处理，
        // 拿不到通道时只会留一行 fg_unavailable 日志，不影响采集。
        // 这里必须保证每个分支都回一个结果，否则 Dart 侧的 Future 会一直挂着
        // （Android 12+ 后台启动前台服务会抛 ForegroundServiceStartNotAllowedException）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.wjmagit.heartrateshare/foreground",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        BleKeepAliveService.start(applicationContext)
                        result.success(true)
                    }
                    "stop" -> {
                        BleKeepAliveService.stop(applicationContext)
                        result.success(true)
                    }
                    "permissions" -> {
                        val missing = requiredPermissions().filter { !isGranted(it) }
                        if (missing.isEmpty()) {
                            result.success(permissionState())
                        } else {
                            pendingPermissionResult = result
                            requestPermissions(
                                missing.toTypedArray(),
                                PERMISSION_REQUEST_CODE,
                            )
                        }
                    }
                    // 只查状态，不弹系统对话框（设置页展示用）。
                    "permissionState" -> result.success(permissionState())
                    // 打开本应用的系统设置页：用户拒绝后唯一的补救入口。
                    "appSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("foreground_service_failed", error.message, error.javaClass.simpleName)
            }
        }
    }

    private companion object {
        const val PERMISSION_REQUEST_CODE = 4711
    }
}
