package com.wjmagit.heartrateshare

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.view.View

/**
 * 悬浮窗里的迷你心率折线。
 *
 * **不自己算时间窗口 / BPM 量程**：点由 Dart 侧 `normalizedPolyline` 算成 0..1
 * 归一化坐标传下来（首页 132dp 大图与这里共用同一份画法），本类只做缩放与描边，
 * 保证大小图不会画出两条不同的线。
 */
class OverlaySparklineView(context: Context) : View(context) {
    /** 归一化折线：每段是扁平的 `[x0,y0,x1,y1,...]`，x/y 都在 0..1（y=0 在顶部）。 */
    var segments: List<FloatArray> = emptyList()
        set(value) {
            field = value
            invalidate()
        }

    /** 短缺测过渡线：每项 `[x0,y0,x1,y1]`（同样 0..1），画成淡色虚线。 */
    var bridges: List<FloatArray> = emptyList()
        set(value) {
            field = value
            invalidate()
        }

    private val density = resources.displayMetrics.density

    // 深色光晕垫底：背景可以全透明，浅色壁纸上也得看得见这条线。
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density + 2f
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        color = Color.argb(120, 0, 0, 0)
    }

    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        // 与 Dart 侧 HeartRateChartStyle.line 同一个 ARGB（首页大图同色）。
        color = CHART_LINE_COLOR
    }

    // 缺测过渡：同色但只有 45% 不透明 + 虚线，看得出"这段没有采样"。
    private val bridgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        strokeCap = Paint.Cap.ROUND
        color = Color.argb(115, 255, 82, 82)
        pathEffect = DashPathEffect(floatArrayOf(3f * density, 2.5f * density), 0f)
    }

    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = CHART_LINE_COLOR
    }

    private val baseline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = density
        color = Color.argb(90, 255, 255, 255)
    }

    override fun onDraw(canvas: Canvas) {
        val width = width - paddingLeft - paddingRight
        val height = height - paddingTop - paddingBottom
        if (width <= 0 || height <= 0) return
        val left = paddingLeft.toFloat()
        val top = paddingTop.toFloat()

        fun px(x: Float) = left + x.coerceIn(0f, 1f) * width
        fun py(y: Float) = top + y.coerceIn(0f, 1f) * height

        if (segments.isEmpty()) {
            // 还没有采样：一条静止基线，不画假曲线。
            val y = py(0.5f)
            canvas.drawLine(px(0f), y, px(1f), y, baseline)
            return
        }

        val path = Path()
        for (segment in segments) {
            if (segment.size < 2) continue
            path.moveTo(px(segment[0]), py(segment[1]))
            var index = 2
            while (index + 1 < segment.size) {
                path.lineTo(px(segment[index]), py(segment[index + 1]))
                index += 2
            }
        }
        canvas.drawPath(path, halo)
        canvas.drawPath(path, stroke)

        for (edge in bridges) {
            if (edge.size < 4) continue
            canvas.drawLine(px(edge[0]), py(edge[1]), px(edge[2]), py(edge[3]), bridgePaint)
        }

        val last = segments.last()
        if (last.size >= 2) {
            canvas.drawCircle(px(last[last.size - 2]), py(last[last.size - 1]), 2f * density, dot)
        }
    }

    private companion object {
        const val CHART_LINE_COLOR = 0xFFFF5252.toInt()
    }
}
