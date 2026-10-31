package com.wjmagit.heartrateshare

import android.Manifest
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// 更新相关通道：ABI、APK 体检（包名/版本/签名）、安装授权、拉起安装器、打开浏览器。
    /// 安装**永远**走系统安装器让用户确认，这里不做静默安装。
    private fun registerUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.wjmagit.heartrateshare/update",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "abi" -> result.success(preferredAbi())
                    "inspectApk" -> result.success(inspectApk(call.argument<String>("path")))
                    "canInstall" -> result.success(canInstall())
                    "openInstallSettings" -> result.success(openInstallSettings())
                    "install" -> result.success(installApk(call.argument<String>("path")))
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("update_failed", error.message, error.javaClass.simpleName)
            }
        }
    }

    /// 本机首选 ABI（SUPPORTED_ABIS 已经是"优先在前"的顺序）。
    private fun preferredAbi(): String {
        val known = setOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
        return Build.SUPPORTED_ABIS.firstOrNull { it in known } ?: "unknown"
    }

    /// 只用 PackageManager 解析文件头，不执行包里的任何代码。
    private fun inspectApk(path: String?): Map<String, Any?>? {
        if (path.isNullOrEmpty()) return null
        if (!java.io.File(path).isFile) return null
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val archive = packageManager.getPackageArchiveInfo(path, flags) ?: return null
        val signer = signerSha256(archive)
        val self = ownSignerSha256()
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            archive.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            archive.versionCode.toLong()
        }
        return mapOf(
            "packageName" to archive.packageName,
            "versionCode" to versionCode.toInt(),
            "versionName" to (archive.versionName ?: ""),
            "signerSha256" to (signer ?: ""),
            // 覆盖安装的前提：包名相同 + 签名一致。这里直接给出结论，Dart 侧不用再比字符串。
            "sameSignerAsThisApp" to (signer != null && self != null && signer == self),
        )
    }

    private fun signerSha256(info: PackageInfo): String? {
        val bytes: ByteArray? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return null
            val signers = if (signing.hasMultipleSigners()) {
                signing.apkContentsSigners
            } else {
                signing.signingCertificateHistory
            }
            signers.firstOrNull()?.toByteArray()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.firstOrNull()?.toByteArray()
        }
        if (bytes == null) return null
        return java.security.MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun ownSignerSha256(): String? = try {
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(
            packageName,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                PackageManager.GET_SIGNATURES
            },
        )
        signerSha256(info)
    } catch (error: Exception) {
        null
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return true
    }

    /// FileProvider 的 content:// URI + 系统安装器；绝不把 file:// 交出去。
    private fun installApk(path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        val file = java.io.File(path)
        if (!file.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        return true
    }

    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        val parsed = Uri.parse(url)
        if (parsed.scheme != "https" && parsed.scheme != "http") return false
        startActivity(
            Intent(Intent.ACTION_VIEW, parsed).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return true
    }

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
        registerOverlayChannel(flutterEngine)
        registerUpdateChannel(flutterEngine)
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

    /**
     * 系统悬浮窗通道：只服务"心率悬浮窗"这一个功能（`SYSTEM_ALERT_WINDOW`），
     * 不申请任何无关权限。窗口本体在前台保活服务里，这里只做转发与授权页。
     *
     * `alpha` 是**背景**不透明度（0 = 全透明）；每个成员可带 `points`（归一化折线），
     * 内容（文字/折线）永远不透明。
     */
    private fun registerOverlayChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.wjmagit.heartrateshare/overlay",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "permissionState" -> result.success(Settings.canDrawOverlays(this))
                    "requestPermission" -> {
                        // 只有用户主动打开开关时才会走到这里，不在启动时弹。
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "show" -> result.success(
                        BleKeepAliveService.showOverlay(
                            this,
                            overlayMembers(call),
                            call.argument<Double>("alpha") ?: 0.85,
                        ),
                    )
                    "update" -> result.success(
                        BleKeepAliveService.updateOverlay(this, overlayMembers(call)),
                    )
                    "alpha" -> {
                        BleKeepAliveService.setOverlayAlpha(
                            this,
                            call.argument<Double>("alpha") ?: 1.0,
                        )
                        result.success(true)
                    }
                    "hide" -> {
                        BleKeepAliveService.hideOverlay(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("overlay_failed", error.message, error.javaClass.simpleName)
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun overlayMembers(call: MethodCall): List<Map<String, Any?>> =
        (call.argument<List<*>>("members") ?: emptyList<Any?>())
            .filterIsInstance<Map<String, Any?>>()

    private companion object {
        const val PERMISSION_REQUEST_CODE = 4711
    }
}
