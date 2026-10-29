package com.wjmagit.heartrateshare

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("foreground_service_failed", error.message, error.javaClass.simpleName)
            }
        }
    }
}
