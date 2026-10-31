package com.wjmagit.heartrateshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 只做两件事：把进程钉在前台优先级（BLE/房间保活），以及**可选的系统悬浮窗**。
 *
 * 背景：targetSdk 36 下，普通后台进程持有的 GATT/WebSocket 会被系统回收。
 * GATT 与 WebSocket 都跑在 Flutter 主进程里，本服务不碰它们，因此不需要额外权限，
 * 也不改变采集/重连逻辑。
 *
 * 悬浮窗为什么挂在这里而不是再起一个服务：房间连上时本来就有 'room' 租约（前台
 * 服务在跑），窗口的生命周期正好等于"在房间里 + 用户开关打开"；独立服务会多一份
 * 定时器/生命周期，容易出现重复窗口。窗口只在本服务存在时挂，`hideOverlay()`
 * 在 onDestroy 里兜底移除，避免泄漏。
 *
 * 悬浮窗外观：每人一行 `名称 | 心率 | 迷你折线`，窗口 wrap_content，可拖动，
 * 背景不透明度 0..1（内容永远 100% 不透明）。
 */
class BleKeepAliveService : Service() {
    private var overlayView: View? = null
    private var overlayRows: LinearLayout? = null
    private var overlayScroll: ScrollView? = null
    private var dynamicNameWidth = 0
    private var dynamicBpmWidth = 0
    private var overlayBackground: GradientDrawable? = null
    private var windowManager: WindowManager? = null
    private var prefs: SharedPreferences? = null
    private var drag: DragState? = null

    private final class DragState(
        val startX: Int,
        val startY: Int,
        val touchX: Float,
        val touchY: Float,
    )

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        hideOverlay()
        instance = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------- 悬浮窗

    /** 权限是否已授予（只查，不申请）。 */
    fun canDrawOverlay(): Boolean = Settings.canDrawOverlays(this)

    /**
     * 显示/刷新悬浮窗。返回 false 表示没显示（无权限、服务不在前台）。
     * 重复调用只更新内容，不会叠出第二个窗口。
     *
     * [backgroundAlpha] 只作用于背景 drawable；文字与折线永远不透明。
     */
    fun showOverlay(members: List<Map<String, Any?>>, backgroundAlpha: Double): Boolean {
        if (!canDrawOverlay()) {
            hideOverlay()
            return false
        }
        val manager = windowManager ?: return false
        val root = overlayView ?: buildOverlay().also { view ->
            manager.addView(view, overlayParams())
            overlayView = view
            restorePosition(view)
        }
        applyBackgroundAlpha(backgroundAlpha)
        renderMembers(members)
        return true
    }

    /** 成员/折线变化：只重建行，不动窗口本身。 */
    fun updateOverlay(members: List<Map<String, Any?>>): Boolean {
        val view = overlayView ?: return false
        if (!canDrawOverlay()) {
            // 权限被用户在系统设置里撤销：立刻清掉，别留一个不可见的僵尸窗口。
            hideOverlay()
            return false
        }
        renderMembers(members)
        return true
    }

    /** 用户拖动的「背景」不透明度：0 = 完全透明。 */
    fun setOverlayAlpha(backgroundAlpha: Double) {
        applyBackgroundAlpha(backgroundAlpha)
    }

    fun hideOverlay() {
        drag = null
        overlayView?.let { view ->
            runCatching { windowManager?.removeView(view) }
        }
        overlayView = null
        overlayRows = null
        overlayScroll = null
        overlayBackground = null
    }

    private fun overlayParams(): WindowManager.LayoutParams = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        },
        // 只有 NOT_FOCUSABLE：必须能接触摸才拖得动，同时又不能抢走输入焦点。
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = prefs?.getInt(KEY_X, UNSET) ?: UNSET
        y = prefs?.getInt(KEY_Y, UNSET) ?: UNSET
    }

    private fun buildOverlay(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(8), dp(8), dp(8))
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(BACKGROUND_COLOR)
            }.also { overlayBackground = it }
            setOnTouchListener(dragListener())
        }

        val rows = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setOnTouchListener(dragListener())
        }
        overlayRows = rows

        val scroll = RowsScrollView(this).apply {
            isFillViewport = false
            addView(rows)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        overlayScroll = scroll
        root.addView(scroll)
        return root
    }

    private fun renderMembers(members: List<Map<String, Any?>>) {
        val rows = overlayRows ?: return
        rows.removeAllViews()
        // 名称列 = 房间内最长名字的渲染宽度（同一房间所有行共用，短名字留白但心率位置对齐）。
        // 与 lib/theme/overlay_metrics.dart 的 computeOverlayLayout 同一规则：
        // nameWidth = max(measure(name)) + 2dp；bpmWidth = measure("888") + 2dp。
        val namePaint = Paint().apply {
            textSize = dp(12).toFloat()
            typeface = Typeface.DEFAULT
        }
        val bpmPaint = Paint().apply {
            textSize = dp(13).toFloat()
            typeface = Typeface.DEFAULT_BOLD
        }
        var longest = namePaint.measureText("宽")
        for (member in members) {
            val name = member["name"] as? String ?: "未命名成员"
            val width = namePaint.measureText(name)
            if (width > longest) longest = width
        }
        // 上限：屏宽 60%（超过才省略），与 Dart 侧 nameMaxScreenRatio 一致。
        val cap = resources.displayMetrics.widthPixels * 0.6f
        dynamicNameWidth = min(longest + dp(NAME_EXTRA_DP), cap)
        dynamicBpmWidth = bpmPaint.measureText("888") + dp(NAME_EXTRA_DP)
        if (members.isEmpty()) {
            rows.addView(memberRow("等待成员加入房间", null, true, emptyList(), emptyList()))
        } else {
            for (member in members) {
                val name = member["name"] as? String ?: "未命名成员"
                val online = member["online"] as? Boolean ?: false
                val bpm = (member["bpm"] as? Number)?.toInt()
                rows.addView(
                    memberRow(name, bpm, !online, segmentsOf(member), bridgesOf(member)),
                )
            }
        }
        // 1 人就是一行高，多人按行增长；超过上限就在窗口内部滚动。
        rows.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        val scroll = overlayScroll ?: return
        scroll.layoutParams = scroll.layoutParams.also {
            it.height = min(rows.measuredHeight, dp(MAX_ROWS_DP))
        }
        clampInPlace()
    }

    /** 一行：名称（左，过长省略）| 心率（右对齐，定宽防抖）| 迷你折线（定宽）。 */
    private fun memberRow(
        name: String,
        bpm: Int?,
        offline: Boolean,
        points: List<FloatArray>,
        bridges: List<FloatArray>,
    ): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        row.addView(
            TextView(this).apply {
                text = name
                setTextColor(if (offline) TEXT_OFFLINE else Color.WHITE)
                textSize = 12f
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                // 定宽（= 房间内最长名宽）+ 省略号：短名字留白，心率位置不跳。
                width = dynamicNameWidth
                outline()
            },
        )
        row.addView(
            TextView(this).apply {
                text = when {
                    offline -> "离线"
                    bpm == null -> "无读数"
                    else -> "$bpm"
                }
                setTextColor(if (offline) TEXT_OFFLINE else CHART_LINE_COLOR)
                textSize = 13f
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.END
                // 定宽 + 右对齐：心率位数变化时右侧折线不会左右抖。
                width = dynamicBpmWidth
                outline()
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginStart = dp(GAP_DP) }
            },
        )
        // 关掉「显示折线图」时 Dart 侧不传点：这一行就只剩名称 + 心率，窗口随之变窄。
        if (points.isNotEmpty()) {
            row.addView(
                OverlaySparklineView(this).apply {
                    segments = points
                    this.bridges = bridges
                    layoutParams = LinearLayout.LayoutParams(dp(CHART_WIDTH_DP), dp(CHART_HEIGHT_DP))
                        .apply { marginStart = dp(GAP_DP) }
                },
            )
        }
        return row
    }

    /** 深色描边：背景可全透明，浅色/深色壁纸上都要读得清。 */
    private fun TextView.outline() {
        setShadowLayer(3f, 0f, 1f, OUTLINE_COLOR)
    }

    // ------------------------------------------------------------------ 拖动

    /**
     * 按住窗口任意位置拖动，实时跟随；松手落盘，下次回到这里。
     *
     * 行列表超出高度上限时，列表会先拦下竖向拖动去滚动内容，横向仍可拖窗口
     * （`RowsScrollView` 只在真的能滚动时才拦截）。
     */
    private fun dragListener() = View.OnTouchListener { _, event ->
        val view = overlayView ?: return@OnTouchListener false
        val params = view.layoutParams as? WindowManager.LayoutParams
            ?: return@OnTouchListener false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                drag = DragState(params.x, params.y, event.rawX, event.rawY)
                true
            }
            MotionEvent.ACTION_MOVE -> {
                val state = drag ?: return@OnTouchListener false
                params.x = clampX((state.startX + (event.rawX - state.touchX)).roundToInt())
                params.y = clampY((state.startY + (event.rawY - state.touchY)).roundToInt())
                // 必须用挂到 WindowManager 上的那个 view 更新，不能用被触摸的子 view。
                runCatching { windowManager?.updateViewLayout(view, params) }
                true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (drag != null) {
                    drag = null
                    prefs?.edit()?.putInt(KEY_X, params.x)?.putInt(KEY_Y, params.y)?.apply()
                }
                true
            }
            else -> false
        }
    }

    /** 首次显示放回原来的右上角；之后回到上次松手的位置，并夹进屏幕。 */
    private fun restorePosition(view: View) {
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return
        view.post {
            val screen = screenSize()
            if (params.x == UNSET || params.y == UNSET) {
                params.x = (screen.x - view.width - dp(16)).coerceAtLeast(0)
                params.y = dp(160)
            } else {
                params.x = clampX(params.x)
                params.y = clampY(params.y)
            }
            runCatching { windowManager?.updateViewLayout(view, params) }
        }
    }

    /** 屏幕旋转/行数变化后把窗口夹回可视区域，不越界。 */
    private fun clampInPlace() {
        val view = overlayView ?: return
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return
        if (view.width == 0 || view.height == 0) return
        val x = clampX(params.x)
        val y = clampY(params.y)
        if (x == params.x && y == params.y) return
        params.x = x
        params.y = y
        runCatching { windowManager?.updateViewLayout(view, params) }
    }

    private fun clampX(x: Int): Int {
        val screen = screenSize()
        val width = overlayView?.width ?: 0
        return x.coerceIn(0, (screen.x - width).coerceAtLeast(0))
    }

    private fun clampY(y: Int): Int {
        val screen = screenSize()
        val height = overlayView?.height ?: 0
        return y.coerceIn(0, (screen.y - height).coerceAtLeast(0))
    }

    private fun screenSize(): Point {
        val manager = windowManager
        if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = manager.currentWindowMetrics.bounds
            return Point(bounds.width(), bounds.height())
        }
        @Suppress("DEPRECATION")
        val metrics = resources.displayMetrics
        return Point(metrics.widthPixels, metrics.heightPixels)
    }

    private fun applyBackgroundAlpha(alpha: Double) {
        // 只有背景变透明：内容是 100% 不透明的，这里绝不设置 view.alpha。
        val colors = BACKGROUND_COLOR
        val argb = Color.argb(
            (alpha.coerceIn(0.0, 1.0) * 255).roundToInt(),
            Color.red(colors),
            Color.green(colors),
            Color.blue(colors),
        )
        overlayBackground?.setColor(argb)
    }

    private fun bridgesOf(member: Map<String, Any?>): List<FloatArray> =
        (member["bridges"] as? List<*>).orEmpty()
            .filterIsInstance<List<*>>()
            .mapNotNull { raw ->
                val floats = raw.mapNotNull { (it as? Number)?.toFloat() }
                if (floats.size < 4) null else floats.toFloatArray()
            }

    private fun segmentsOf(member: Map<String, Any?>): List<FloatArray> =
        (member["points"] as? List<*>).orEmpty()
            .filterIsInstance<List<*>>()
            .mapNotNull { raw ->
                val floats = raw.mapNotNull { (it as? Number)?.toFloat() }
                if (floats.size < 2) null else floats.toFloatArray()
            }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    /**
     * 只在内容真的超出高度上限时才拦截竖向拖动（内部滚动）；否则不拦，
     * 让外层把拖动当成"拖窗口"。
     */
    private class RowsScrollView(context: Context) : ScrollView(context) {
        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean =
            (canScrollVertically(1) || canScrollVertically(-1)) &&
                super.onInterceptTouchEvent(ev)
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "心率采集",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("正在采集心率")
            .setContentText("保持与心率带的连接，息屏后继续共享")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "hrs_keepalive"
        private const val NOTIFICATION_ID = 1001

        /** 悬浮窗位置（原生自己存：位置是本机窗口状态，与 Dart 侧偏好无关）。 */
        private const val PREFS = "hrs_overlay"
        private const val KEY_X = "x"
        private const val KEY_Y = "y"
        private const val UNSET = Int.MIN_VALUE

        /** 行数上限对应的最大高度（dp），超出就在窗口内部滚动。 */
        private const val MAX_ROWS_DP = 220
        // 与 lib/theme/overlay_metrics.dart 一一对应（CI 里有比对测试，改一处必须改两处）。
        private const val GAP_DP = 8
        private const val NAME_EXTRA_DP = 2
        private const val CHART_WIDTH_DP_FALLBACK = 72
        private const val CHART_WIDTH_DP = 72
        private const val CHART_HEIGHT_DP = 20

        /** 背景底色（不透明度由用户滑块决定，0 = 全透明）。 */
        private const val BACKGROUND_COLOR = 0xFF1C1C1E.toInt()
        private const val TEXT_OFFLINE = 0xFFB0B0B0.toInt()

        /** 与 Dart 侧 HeartRateChartStyle.line 同一个 ARGB。 */
        private const val CHART_LINE_COLOR = 0xFFFF5252.toInt()
        private const val OUTLINE_COLOR = 0xCC000000.toInt()

        private var instance: BleKeepAliveService? = null

        fun start(context: Context) {
            val intent = Intent(context, BleKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BleKeepAliveService::class.java))
        }

        /** 服务没在跑（没有房间/BLE 连接）时返回 false，Dart 侧据此降级。 */
        fun showOverlay(
            context: Context,
            members: List<Map<String, Any?>>,
            alpha: Double,
        ): Boolean {
            val service = instance ?: return false
            if (!Settings.canDrawOverlays(context)) return false
            return service.showOverlay(members, alpha)
        }

        fun updateOverlay(context: Context, members: List<Map<String, Any?>>): Boolean =
            instance?.updateOverlay(members) ?: false

        fun setOverlayAlpha(context: Context, alpha: Double) {
            instance?.setOverlayAlpha(alpha)
        }

        fun hideOverlay(context: Context) {
            instance?.hideOverlay()
        }
    }
}
