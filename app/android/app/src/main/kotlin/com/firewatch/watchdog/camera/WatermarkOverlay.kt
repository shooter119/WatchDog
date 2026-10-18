package com.firewatch.watchdog.camera

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import kotlin.math.min

/**
 * 现场水印版式（对齐消防通讯常用的水印相机样式）。
 *
 * 左下角一块白色信息卡：
 *   ┌───────────────────────────────┐
 *   │ [徽标]  单位全称（蓝底白字）      │
 *   ├───────────────────────────────┤
 *   │ 拍摄  │ 2026.10.18 星期日 08:39 │
 *   │ 时间  │                         │
 *   │ 天气  │ 晴 21℃ 东南风2级 湿度87% │
 *   │ 地点  │ 衢州市 · 某某有限公司     │
 *   │ 经度  │ 东经 118°22′            │
 *   │ 纬度  │ 北纬 29°0′              │
 *   ├───────────────────────────────┤
 *   │ 拍摄单位：…（蓝底白字）           │
 *   └───────────────────────────────┘
 *
 * 尺寸全部按画面宽度等比计算，720p / 1080p / 4K 观感一致。
 */
object WatermarkOverlay {

    private const val CARD_WIDTH_RATIO = 0.58f
    private const val MARGIN_RATIO = 0.026f
    private const val HEADER_RATIO = 0.150f // 相对卡片宽度
    private const val FOOTER_RATIO = 0.092f
    private const val ROW_RATIO = 0.104f
    private const val LABEL_COLUMN_RATIO = 0.175f

    private val BLUE = Color.rgb(42, 114, 212)
    private val CARD_BG = Color.WHITE
    private val TEXT_MAIN = Color.rgb(26, 26, 26)
    private val EMBLEM_RED = Color.rgb(200, 16, 46)

    private data class Row(
        val label: String,
        val value: String,
        val valueLines: Int = 1,
    )

    fun draw(canvas: Canvas, model: WatermarkModel) {
        val width = canvas.width
        val height = canvas.height
        if (width <= 0 || height <= 0) return

        val rows = buildRows(model)
        if (rows.isEmpty() && model.unitTitle.isBlank() && model.department.isBlank()) return

        val cardWidth = width * CARD_WIDTH_RATIO
        val margin = width * MARGIN_RATIO
        val headerHeight = cardWidth * HEADER_RATIO
        val footerHeight = if (model.department.isBlank()) 0f else cardWidth * FOOTER_RATIO
        val rowHeight = cardWidth * ROW_RATIO
        val bodyHeight = rows.sumOf { (rowHeight * it.valueLines).toDouble() }.toFloat()
        val cardHeight = headerHeight + bodyHeight + footerHeight

        val left = margin
        val top = height - margin - cardHeight
        val card = RectF(left, top, left + cardWidth, top + cardHeight)

        drawCard(canvas, card, cardWidth)
        drawHeader(canvas, model, card, cardWidth, headerHeight)
        drawBody(canvas, rows, card, cardWidth, headerHeight, rowHeight)
        if (footerHeight > 0f) {
            drawFooter(canvas, model, card, cardWidth, headerHeight + bodyHeight, footerHeight)
        }
    }

    private fun buildRows(model: WatermarkModel): List<Row> {
        val rows = mutableListOf<Row>()
        if (model.showTime) rows.add(Row("拍摄时间", model.dateText))
        if (model.showWeather && model.weather.isNotBlank()) {
            rows.add(Row("天气", model.weather, valueLines = if (model.weather.length > 18) 2 else 1))
        }
        if (model.showLocation && model.address.isNotBlank()) {
            rows.add(Row("地点", model.address, valueLines = if (model.address.length > 20) 2 else 1))
        }
        if (model.showCoordinates && model.latitude != null && model.longitude != null) {
            rows.add(Row("经度", longitudeText(model)))
            rows.add(Row("纬度", latitudeText(model)))
        }
        if (model.actorName.isNotBlank()) rows.add(Row("拍摄人", model.actorName))
        return rows
    }

    private fun longitudeText(model: WatermarkModel): String {
        val lon = model.longitude ?: return ""
        val prefix = if (lon >= 0) "东经" else "西经"
        return "$prefix ${WatermarkModel.dms(lon)}"
    }

    private fun latitudeText(model: WatermarkModel): String {
        val lat = model.latitude ?: return ""
        val prefix = if (lat >= 0) "北纬" else "南纬"
        return "$prefix ${WatermarkModel.dms(lat)}"
    }

    private fun drawCard(canvas: Canvas, card: RectF, cardWidth: Float) {
        val radius = cardWidth * 0.030f
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(60, 0, 0, 0)
        }
        canvas.drawRoundRect(
            RectF(card.left + cardWidth * 0.004f, card.top + cardWidth * 0.006f, card.right, card.bottom),
            radius,
            radius,
            shadow,
        )
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CARD_BG }
        canvas.drawRoundRect(card, radius, radius, background)
    }

    private fun drawHeader(
        canvas: Canvas,
        model: WatermarkModel,
        card: RectF,
        cardWidth: Float,
        headerHeight: Float,
    ) {
        val radius = cardWidth * 0.030f
        val clip = Path().apply {
            addRoundRect(
                RectF(card.left, card.top, card.right, card.top + headerHeight + radius),
                floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f),
                Path.Direction.CW,
            )
        }
        canvas.save()
        canvas.clipPath(clip)
        val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BLUE }
        canvas.drawRect(card.left, card.top, card.right, card.top + headerHeight, headerPaint)
        canvas.restore()

        val emblemSize = headerHeight * 0.72f
        val emblemLeft = card.left + headerHeight * 0.16f
        val emblemTop = card.top + (headerHeight - emblemSize) / 2f
        if (model.showLogo) {
            drawEmblem(canvas, RectF(emblemLeft, emblemTop, emblemLeft + emblemSize, emblemTop + emblemSize))
        }

        val textLeft = if (model.showLogo) emblemLeft + emblemSize + headerHeight * 0.16f else card.left + headerHeight * 0.22f
        val title = model.unitTitle.ifBlank { "现场影像" }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = headerHeight * 0.40f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val available = card.right - textLeft - headerHeight * 0.20f
        val shown = if (paint.measureText(title) > available) {
            TextUtils.ellipsize(title, paint, available, TextUtils.TruncateAt.END).toString()
        } else {
            title
        }
        val baseline = card.top + headerHeight / 2f - (paint.ascent() + paint.descent()) / 2f
        canvas.drawText(shown, textLeft, baseline, paint)
    }

    /** 通用盾形标识：不复制任何官方徽标，单位可在后续版本替换为自有图片。 */
    private fun drawEmblem(canvas: Canvas, box: RectF) {
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = EMBLEM_RED }
        canvas.drawRoundRect(box, box.width() * 0.14f, box.width() * 0.14f, background)

        val shield = Path().apply {
            val w = box.width()
            val h = box.height()
            val cx = box.centerX()
            val top = box.top + h * 0.18f
            moveTo(cx, top)
            lineTo(cx + w * 0.28f, top + h * 0.10f)
            lineTo(cx + w * 0.26f, top + h * 0.42f)
            quadraticTo(cx + w * 0.24f, top + h * 0.66f, cx, top + h * 0.76f)
            quadraticTo(cx - w * 0.24f, top + h * 0.66f, cx - w * 0.26f, top + h * 0.42f)
            lineTo(cx - w * 0.28f, top + h * 0.10f)
            close()
        }
        val shieldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = box.width() * 0.045f
        }
        canvas.drawPath(shield, shieldPaint)

        val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        val barWidth = box.width() * 0.075f
        canvas.drawRoundRect(
            RectF(
                box.centerX() - barWidth / 2f,
                box.top + box.height() * 0.34f,
                box.centerX() + barWidth / 2f,
                box.top + box.height() * 0.62f,
            ),
            barWidth / 2f,
            barWidth / 2f,
            barPaint,
        )
    }

    private fun drawBody(
        canvas: Canvas,
        rows: List<Row>,
        card: RectF,
        cardWidth: Float,
        headerHeight: Float,
        rowHeight: Float,
    ) {
        if (rows.isEmpty()) return
        val labelColumnWidth = cardWidth * LABEL_COLUMN_RATIO
        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TEXT_MAIN
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val valuePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TEXT_MAIN
            typeface = Typeface.DEFAULT
        }
        val dividerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(38, 0, 0, 0)
            strokeWidth = cardWidth * 0.0025f
        }

        var cursor = card.top + headerHeight
        rows.forEachIndexed { index, row ->
            val height = rowHeight * row.valueLines
            val centerY = cursor + height / 2f

            // 标签：两字一行，最多两行，居中对齐
            val labelLines = splitLabel(row.label)
            labelPaint.textSize = rowHeight * 0.30f
            val lineHeight = labelPaint.textSize * 1.16f
            val labelBlockHeight = lineHeight * labelLines.size
            var labelY = centerY - labelBlockHeight / 2f + labelPaint.textSize
            labelLines.forEach { line ->
                val lineWidth = labelPaint.measureText(line)
                canvas.drawText(
                    line,
                    card.left + (labelColumnWidth - lineWidth) / 2f + cardWidth * 0.012f,
                    labelY,
                    labelPaint,
                )
                labelY += lineHeight
            }

            // 分隔竖线
            canvas.drawLine(
                card.left + labelColumnWidth + cardWidth * 0.014f,
                cursor + height * 0.18f,
                card.left + labelColumnWidth + cardWidth * 0.014f,
                cursor + height * 0.82f,
                dividerPaint,
            )

            // 值：按可用宽度自动字号，超长自动缩到两行上限
            val valueLeft = card.left + labelColumnWidth + cardWidth * 0.032f
            val maxValueWidth = card.right - valueLeft - cardWidth * 0.022f
            valuePaint.textSize = rowHeight * 0.335f
            val lines = wrapText(row.value, valuePaint, maxValueWidth, maxLines = row.valueLines)
            val valueLineHeight = valuePaint.textSize * 1.24f
            val valueBlockHeight = valueLineHeight * lines.size
            var valueY = centerY - valueBlockHeight / 2f + valuePaint.textSize
            lines.forEach { line ->
                canvas.drawText(line, valueLeft, valueY, valuePaint)
                valueY += valueLineHeight
            }

            cursor += height

            if (index < rows.size - 1) {
                canvas.drawLine(
                    card.left + cardWidth * 0.018f,
                    cursor,
                    card.right - cardWidth * 0.018f,
                    cursor,
                    dividerPaint,
                )
            }
        }
    }

    private fun drawFooter(
        canvas: Canvas,
        model: WatermarkModel,
        card: RectF,
        cardWidth: Float,
        bodyBottom: Float,
        footerHeight: Float,
    ) {
        val radius = cardWidth * 0.030f
        val clip = Path().apply {
            addRoundRect(
                RectF(card.left, bodyBottom - radius, card.right, card.bottom),
                floatArrayOf(0f, 0f, 0f, 0f, radius, radius, radius, radius),
                Path.Direction.CW,
            )
        }
        canvas.save()
        canvas.clipPath(clip)
        canvas.drawRect(
            card.left,
            bodyBottom,
            card.right,
            card.bottom,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BLUE },
        )
        canvas.restore()

        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = footerHeight * 0.46f
            typeface = Typeface.DEFAULT
        }
        val labelWidth = paint.measureText("拍摄单位：")
        val text = "拍摄单位：${model.department}"
        val available = card.right - card.left - cardWidth * 0.06f
        val shown = if (paint.measureText(text) > available) {
            val room = available - labelWidth
            val dept = TextUtils.ellipsize(
                model.department,
                paint,
                room.coerceAtLeast(0f),
                TextUtils.TruncateAt.END,
            ).toString()
            "拍摄单位：$dept"
        } else {
            text
        }
        val baseline = bodyBottom + footerHeight / 2f - (paint.ascent() + paint.descent()) / 2f
        canvas.drawText(shown, card.left + cardWidth * 0.030f, baseline, paint)
    }

    private fun splitLabel(label: String): List<String> {
        if (label.length <= 2) return label.map { it.toString() }
        return listOf(label.substring(0, 2), label.substring(2))
    }

    private fun wrapText(text: String, paint: TextPaint, maxWidth: Float, maxLines: Int): List<String> {
        if (text.isEmpty()) return listOf("")
        val lines = mutableListOf<String>()
        var current = StringBuilder()
        var currentWidth = 0f
        for (char in text) {
            val charWidth = paint.measureText(char.toString())
            if (currentWidth + charWidth > maxWidth && current.isNotEmpty()) {
                lines.add(current.toString())
                if (lines.size == maxLines) {
                    // 最后一行用省略号收尾，避免超出卡片
                    val last = lines.last()
                    lines[lines.size - 1] = TextUtils.ellipsize(
                        "$last$char",
                        paint,
                        maxWidth,
                        TextUtils.TruncateAt.END,
                    ).toString()
                    return lines
                }
                current = StringBuilder()
                currentWidth = 0f
            }
            current.append(char)
            currentWidth += charWidth
        }
        if (current.isNotEmpty()) lines.add(current.toString())
        return if (lines.isEmpty()) listOf("") else lines.take(maxLines)
    }
}
