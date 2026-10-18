package com.firewatch.watchdog.camera

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import androidx.camera.effects.Frame
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

    private const val CARD_WIDTH_RATIO = 0.50f
    private const val MARGIN_RATIO = 0.018f
    private const val HEADER_RATIO = 0.078f // 相对卡片宽度
    private const val FOOTER_RATIO = 0.062f
    private const val ROW_RATIO = 0.058f
    private const val LABEL_COLUMN_RATIO = 0.175f

    private val DEBUG_LOG = java.util.concurrent.atomic.AtomicBoolean(false)

    private val BLUE = Color.rgb(42, 114, 212)
    private val CARD_BG = Color.WHITE
    private val TEXT_MAIN = Color.rgb(26, 26, 26)
    private val EMBLEM_RED = Color.rgb(200, 16, 46)

    private data class Row(
        val label: String,
        val value: String,
        val valueLines: Int = 1,
    )

    /**
     * 在相机帧上绘制水印。
     *
     * 坐标系问题：OverlayEffect 回调拿到的 Canvas 是**传感器缓冲区坐标**（通常是横向
     * 1280×960），而预览要按 rotationDegrees 旋转后才竖屏显示。直接在缓冲区坐标里排版，
     * 水印会整体转 90° 甚至倒置。
     *
     * 做法：先在「直立坐标系」渲染成一张位图（排版逻辑因此保持直观），再用矩阵把它
     * 旋转贴到帧上。水印内容在拍摄期间是冻结的，位图按内容缓存，每帧只是贴图，开销很小。
     */
    /** 由宿主在启动时注入 Application 上下文，用于解码队徽资源。 */
    @Volatile
    private var appContext: android.content.Context? = null
    @Volatile
    private var appPackageName: String = ""

    fun install(context: android.content.Context) {
        appContext = context.applicationContext
        appPackageName = context.packageName
    }

    private var cachedBitmap: Bitmap? = null
    private var cachedKey: String? = null

    fun draw(canvas: Canvas, frame: Frame, model: WatermarkModel) {
        val buffer = frame.size
        if (buffer.width <= 0 || buffer.height <= 0) return
        val rotation = ((frame.rotationDegrees % 360) + 360) % 360
        val uprightWidth = if (rotation % 180 == 0) buffer.width else buffer.height
        val uprightHeight = if (rotation % 180 == 0) buffer.height else buffer.width
        if (uprightWidth <= 0 || uprightHeight <= 0) return

        // 直立 → 缓冲区 的变换矩阵。
        // 实测 rotationDegrees 是「缓冲区需要顺时针转多少度才直立」，
        // 而这里是从直立坐标往缓冲区贴图，方向相反，必须用 360 - rotation。
        val uprightToBuffer = (360 - rotation) % 360
        val matrix = Matrix()
        matrix.setRotate(uprightToBuffer.toFloat())
        when (uprightToBuffer) {
            90 -> matrix.postTranslate(buffer.width.toFloat(), 0f)
            180 -> matrix.postTranslate(buffer.width.toFloat(), buffer.height.toFloat())
            270 -> matrix.postTranslate(0f, buffer.height.toFloat())
        }
        if (frame.isMirroring) matrix.postScale(-1f, 1f, uprightWidth / 2f, uprightHeight / 2f)

        // 缓冲区里的裁剪框 → 直立坐标（预览实际可见的范围）
        val inverse = Matrix()
        if (!matrix.invert(inverse)) return
        val crop = frame.cropRect
        val corners = floatArrayOf(
            crop.left.toFloat(), crop.top.toFloat(),
            crop.right.toFloat(), crop.top.toFloat(),
            crop.left.toFloat(), crop.bottom.toFloat(),
            crop.right.toFloat(), crop.bottom.toFloat(),
        )
        inverse.mapPoints(corners)
        var minX = corners[0]; var maxX = corners[0]
        var minY = corners[1]; var maxY = corners[1]
        for (i in 2 until corners.size step 2) {
            minX = kotlin.math.min(minX, corners[i]); maxX = kotlin.math.max(maxX, corners[i])
            minY = kotlin.math.min(minY, corners[i + 1]); maxY = kotlin.math.max(maxY, corners[i + 1])
        }
        val visible = if (maxX - minX <= 1f || maxY - minY <= 1f) {
            RectF(0f, 0f, uprightWidth.toFloat(), uprightHeight.toFloat())
        } else {
            RectF(
                minX.coerceAtLeast(0f),
                minY.coerceAtLeast(0f),
                maxX.coerceAtMost(uprightWidth.toFloat()),
                maxY.coerceAtMost(uprightHeight.toFloat()),
            )
        }

        val key = buildString {
            append(uprightWidth).append('x').append(uprightHeight)
            append('|').append(visible)
            append('|').append(model.hashCode())
        }
        val bitmap = if (key == cachedKey && cachedBitmap != null) {
            cachedBitmap!!
        } else {
            val fresh = Bitmap.createBitmap(
                uprightWidth,
                uprightHeight,
                Bitmap.Config.ARGB_8888,
            )
            drawInArea(Canvas(fresh), model, visible)
            cachedBitmap?.recycle()
            cachedBitmap = fresh
            cachedKey = key
            fresh
        }

        if (DEBUG_LOG.compareAndSet(false, true)) {
            android.util.Log.d(
                "WMWatermark",
                "buffer=" + buffer.width + "x" + buffer.height +
                    " rot=" + rotation +
                    " upright=" + uprightWidth + "x" + uprightHeight +
                    " crop=" + frame.cropRect +
                    " mirror=" + frame.isMirroring +
                    " visible=" + visible,
            )
        }

        canvas.drawBitmap(bitmap, matrix, null)
    }

    /** 释放缓存位图；会话结束时调用，避免长时间占用内存。 */
    fun release() {
        cachedBitmap?.recycle()
        cachedBitmap = null
        cachedKey = null
    }

    private fun drawInArea(canvas: Canvas, model: WatermarkModel, area: RectF) {
        val width = area.width()
        if (width <= 0f) return

        val rows = buildRows(model)
        if (rows.isEmpty() && model.unitTitle.isBlank() && model.department.isBlank()) return

        // 固定比例：信息卡的尺寸只与画面宽度相关，不随横竖屏或分辨率改变，
        // 保证同一台设备拍出的照片与视频、以及不同机型之间的水印观感一致。
        val cardWidth = width * CARD_WIDTH_RATIO
        val rowRatio = ROW_RATIO
        val margin = width * MARGIN_RATIO
        val headerHeight = cardWidth * HEADER_RATIO
        val footerHeight = if (model.department.isBlank()) 0f else cardWidth * FOOTER_RATIO
        val rowHeight = cardWidth * rowRatio
        val bodyHeight = rows.sumOf { (rowHeight * it.valueLines).toDouble() }.toFloat()
        val cardHeight = headerHeight + bodyHeight + footerHeight

        val left = area.left + margin
        // 卡片贴可见区域底部：竖屏录制时缓冲区底部才是画面底部
        val top = area.bottom - margin - cardHeight
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

        val emblemSize = headerHeight * 0.92f
        val emblemLeft = card.left + headerHeight * 0.10f
        val emblemTop = card.top + (headerHeight - emblemSize) / 2f
        if (model.showLogo) {
            drawEmblem(canvas, RectF(emblemLeft, emblemTop, emblemLeft + emblemSize, emblemTop + emblemSize))
        }

        val textLeft = if (model.showLogo) emblemLeft + emblemSize + headerHeight * 0.22f else card.left + headerHeight * 0.22f
        val title = model.unitTitle.ifBlank { "现场影像" }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = headerHeight * 0.44f
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

    /**
     * 绘制中国消防救援队徽。
     *
     * 徽标来源：Wikimedia Commons「CHINA FIRE AND RESCUE badge.svg」，标注 Public domain
     * （中华人民共和国官方标志不受著作权保护）。资源放在 res/drawable-nodpi/，
     * 不按屏幕密度缩放，保证水印内尺寸只由版式比例决定。
     * 解码失败时回落到红底盾形占位，不阻断拍摄。
     */
    private fun drawEmblem(canvas: Canvas, box: RectF) {
        val badge = emblemBitmap()
        if (badge == null) {
            drawEmblemFallback(canvas, box)
            return
        }
        // 白色圆角底衬托，避免蓝色队徽与蓝色抬头条混在一起
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        val padding = box.width() * 0.03f
        canvas.drawRoundRect(
            RectF(box.left - padding, box.top - padding, box.right + padding, box.bottom + padding),
            box.width() * 0.08f,
            box.width() * 0.08f,
            background,
        )
        // 队徽原始比例 960:1073，按高度适配并水平居中
        val targetHeight = box.height()
        val targetWidth = targetHeight * (badge.width.toFloat() / badge.height.toFloat())
        val left = box.centerX() - targetWidth / 2f
        val src = android.graphics.Rect(0, 0, badge.width, badge.height)
        val dst = RectF(left, box.top, left + targetWidth, box.top + targetHeight)
        canvas.drawBitmap(badge, src, dst, Paint(Paint.FILTER_BITMAP_FLAG))
    }

    @Volatile
    private var cachedEmblem: Bitmap? = null
    @Volatile
    private var emblemLoaded = false

    private fun emblemBitmap(): Bitmap? {
        if (emblemLoaded) return cachedEmblem
        synchronized(this) {
            if (!emblemLoaded) {
                cachedEmblem = try {
                    val res = appContext?.resources
                    if (res == null) null else {
                        android.graphics.BitmapFactory.decodeResource(
                            res,
                            res.getIdentifier("fire_rescue_badge", "drawable", appPackageName),
                        )
                    }
                } catch (_: Throwable) {
                    null
                }
                emblemLoaded = true
            }
        }
        return cachedEmblem
    }

    /** 资源缺失时的占位：红底白色盾形，保证水印结构完整。 */
    private fun drawEmblemFallback(canvas: Canvas, box: RectF) {
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
            quadTo(cx + w * 0.24f, top + h * 0.66f, cx, top + h * 0.76f)
            quadTo(cx - w * 0.24f, top + h * 0.66f, cx - w * 0.26f, top + h * 0.42f)
            lineTo(cx - w * 0.28f, top + h * 0.10f)
            close()
        }
        canvas.drawPath(
            shield,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                style = Paint.Style.STROKE
                strokeWidth = box.width() * 0.045f
            },
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
            labelPaint.textSize = rowHeight * 0.38f
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
            valuePaint.textSize = rowHeight * 0.50f
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
            textSize = footerHeight * 0.52f
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
