package com.firewatch.watchdog.camera

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils

/**
 * 把水印画到相机帧的覆盖层上。
 *
 * 排版固定为三行，底部半透明通栏，不遮挡画面主体：
 *   1. 品牌 · 单位 · 警情
 *   2. 地址 · 天气
 *   3. 拍摄人 · 时间（秒）
 *
 * 字号按画面宽度等比计算，因此 720p / 1080p / 4K 输出观感一致。
 */
object WatermarkOverlay {

    private const val PADDING_RATIO = 0.035f
    private const val TITLE_SIZE_RATIO = 0.030f
    private const val BODY_SIZE_RATIO = 0.026f

    fun draw(canvas: Canvas, model: WatermarkModel) {
        val width = canvas.width
        val height = canvas.height
        if (width <= 0 || height <= 0) return

        val padding = width * PADDING_RATIO
        val titleSize = width * TITLE_SIZE_RATIO
        val bodySize = width * BODY_SIZE_RATIO
        val lineGap = bodySize * 0.42f

        val title = buildTitle(model)
        val place = buildPlace(model)
        val who = buildWho(model)

        val titlePaint = textPaint(titleSize, Typeface.DEFAULT_BOLD, 1f)
        val bodyPaint = textPaint(bodySize, Typeface.DEFAULT, 0.94f)

        val lines = listOf(
            Triple(title, titlePaint, false),
            Triple(place, bodyPaint, true),
            Triple(who, bodyPaint, true),
        )
        val maxTextWidth = width - padding * 2
        val heights = lines.map { it.second.textSize * 1.28f }
        val contentHeight = heights.sum() + lineGap * (lines.size - 1)

        val barHeight = contentHeight + padding * 1.6f
        val barTop = height - barHeight
        drawScrim(canvas, width, height, barTop)

        var y = barTop + padding * 0.8f
        lines.forEachIndexed { index, (raw, paint, ellipsize) ->
            var text = raw
            if (ellipsize && paint.measureText(text) > maxTextWidth) {
                text = TextUtils.ellipsize(text, paint as TextPaint, maxTextWidth, TextUtils.TruncateAt.END).toString()
            }
            y += paint.textSize
            canvas.drawText(text, padding, y, paint)
            y += heights[index] - paint.textSize + lineGap
        }
    }

    private fun buildTitle(model: WatermarkModel): String {
        val parts = mutableListOf("火场智控")
        if (model.unitName.isNotBlank()) parts.add(model.unitName)
        if (model.incidentName.isNotBlank()) parts.add(model.incidentName)
        return parts.joinToString(" · ")
    }

    private fun buildPlace(model: WatermarkModel): String {
        val address = model.address.ifBlank { "位置未获取" }
        return if (model.weather.isBlank()) address else "$address · ${model.weather}"
    }

    private fun buildWho(model: WatermarkModel): String {
        val actor = model.actorName.ifBlank { "未署名" }
        return "拍摄：$actor    ${model.timeText}"
    }

    /** 底部由透明到半透明黑的渐变，保证强光下文字可读，又不形成硬边遮挡。 */
    private fun drawScrim(canvas: Canvas, width: Int, height: Int, barTop: Float) {
        val fadeTop = (barTop - height * 0.06f).coerceAtLeast(0f)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, fadeTop, 0f, height.toFloat(),
                intArrayOf(Color.TRANSPARENT, Color.argb(150, 0, 0, 0), Color.argb(205, 0, 0, 0)),
                floatArrayOf(0f, 0.35f, 1f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRect(0f, fadeTop, width.toFloat(), height.toFloat(), paint)
    }

    private fun textPaint(size: Float, typeface: Typeface, alpha: Float): TextPaint =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.textSize = size
            this.typeface = typeface
            color = Color.WHITE
            this.alpha = (255 * alpha).toInt()
            // 轻微描边阴影，避免浅色画面上文字糊在一起
            setShadowLayer(size * 0.10f, 0f, size * 0.04f, Color.argb(160, 0, 0, 0))
        }
}
