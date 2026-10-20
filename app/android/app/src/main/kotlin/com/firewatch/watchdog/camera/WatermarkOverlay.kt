package com.firewatch.watchdog.camera

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import androidx.camera.effects.Frame
import kotlin.math.min

/**
 * 现场水印版式（对齐消防通讯常用的水印相机样式）。
 *
 * 左下角一块半透明白色信息卡：
 *   ┌───────────────────────────────┐
 *   │ [徽标]  单位全称（半透明蓝底白字） │
 *   ├───────────────────────────────┤
 *   │ 拍 摄 时 间：2026.10.18 星期日 08:39 │
 *   │ 天      气：晴 21℃ 东南风2级 湿度87% │
 *   │ 地      点：衢州市 · 某某有限公司     │
 *   │ 经      度：东经 118°22′            │
 *   │ 纬      度：北纬 29°0′              │
 *   ├───────────────────────────────┤
 *   │ 拍 摄 单 位：…（半透明蓝底白字）     │
 *   └───────────────────────────────┘
 *
 * 版式要点（按现场参考图 3264×2448 实测）：
 * - 卡片宽占画面 32.2%，抬头 232‰、信息行 76.5‰、底条 76‰（均相对卡片宽度）
 * - 标签在固定列内按字符分散对齐，单行显示；数值从 296‰ 处开始
 * - 抬头字号与正文同级，不再用整条抬头高度去撑字；底条字号与正文同级
 * - 白色卡面、蓝色抬头/底条都保留透明度，能透出背景又保证文字可读
 * - 所有尺寸只与画面宽度相关，720p / 1080p / 4K 以及照片、视频观感一致
 */
object WatermarkOverlay {

    private const val CARD_WIDTH_RATIO = 0.322f
    private const val MARGIN_LEFT_RATIO = 0.017f
    private const val MARGIN_BOTTOM_RATIO = 0.017f
    private const val HEADER_RATIO = 0.232f
    private const val FOOTER_RATIO = 0.076f
    private const val ROW_RATIO = 0.0765f
    private const val CORNER_RATIO = 0.026f

    /** 标签列：首字左边缘、末字右边缘、冒号与数值起点，均为卡片宽度的占比。 */
    private const val LABEL_LEFT_RATIO = 0.040f
    private const val LABEL_RIGHT_RATIO = 0.245f
    private const val COLON_RATIO = 0.262f
    private const val VALUE_LEFT_RATIO = 0.296f
    private const val VALUE_RIGHT_PADDING_RATIO = 0.018f

    /** 卡片最多占可见高度的比例，全字段换行时也不会顶出画面上沿。 */
    private const val MAX_CARD_HEIGHT_RATIO = 0.62f

    /** 照片与录像统一按 16:9 裁剪；水印必须落在两种比例都保留的安全区内。 */
    private const val TARGET_ASPECT = 16f / 9f

    private val DEBUG_LOG = java.util.concurrent.atomic.AtomicBoolean(false)

    // 半透明配色：白卡和蓝条都要能透出背景，同时保持黑字/白字的对比度。
    private val BLUE = Color.argb(212, 58, 122, 214)
    private val CARD_BG = Color.argb(158, 255, 255, 255)
    private val TEXT_MAIN = Color.argb(236, 24, 24, 24)
    private val TITLE_TEXT = Color.argb(236, 255, 255, 255)
    private val FOOTER_LABEL = Color.argb(250, 255, 255, 255)
    private val FOOTER_VALUE = Color.argb(218, 255, 255, 255)
    private val DIVIDER = Color.argb(26, 0, 0, 0)
    private val EMBLEM_RED = Color.rgb(200, 16, 46)

    private data class Row(
        val label: String,
        val value: String,
        val maxLines: Int = 1,
    )

    private data class RowLayout(
        val row: Row,
        val lines: List<String>,
        val height: Float,
    )

    private data class CardMetrics(
        val cardWidth: Float,
        val headerHeight: Float,
        val rowHeight: Float,
        val bodyHeight: Float,
        val footerHeight: Float,
        val cardHeight: Float,
        val rows: List<RowLayout>,
    )

    /** 由宿主在启动时注入 Application 上下文，用于解码队徽资源。 */
    @Volatile
    private var appContext: android.content.Context? = null

    @Volatile
    private var appPackageName: String = ""

    // 不同会话有各自的 GL 线程；缓存、Paint 与位图回收共用对象锁，
    // 防止旧会话关闭或快速切镜头时与新会话 draw 并发。
    /** 新会话开始时复位释放标记，返回本次会话的代际号。 */
    @Synchronized
    fun resetForNewSession(): Int {
        released = false
        generation += 1
        return generation
    }

    fun install(context: android.content.Context) {
        appContext = context.applicationContext
        appPackageName = context.packageName
    }

    /** 在无水印母版上绘制同一版式，供照片成片使用。 */
    @Synchronized
    fun drawMedia(canvas: Canvas, width: Int, height: Int, model: WatermarkModel) {
        if (width <= 0 || height <= 0) return
        drawInArea(canvas, model, RectF(0f, 0f, width.toFloat(), height.toFloat()))
    }

    /** 生成透明水印层，供视频转码时上传为 GL 纹理。 */
    @Synchronized
    fun renderMediaOverlay(
        width: Int,
        height: Int,
        model: WatermarkModel,
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(
            width.coerceAtLeast(1),
            height.coerceAtLeast(1),
            Bitmap.Config.ARGB_8888,
        )
        drawMedia(Canvas(bitmap), bitmap.width, bitmap.height, model)
        return bitmap
    }

    private var cachedBitmap: Bitmap? = null
    private var cachedKey: String? = null

    /** 会话释放后置位：绘制线程可能还会再来一帧，禁止再碰位图缓存。 */
    @Volatile
    private var released = false

    /**
     * 会话代际。快速退出再进入时，上一会话的后台释放任务可能在新会话已经开始
     * 绘制之后才执行；带上代际号后，过期的释放任务会被丢弃，不会把新会话的
     * 位图缓存回收掉（那会让重进页面后水印直接消失）。
     */
    private var generation = 0

    @Synchronized
    fun draw(canvas: Canvas, frame: Frame, model: WatermarkModel) {
        // overlayCanvas 会复用旧像素；每帧只清空独立透明水印层，不触碰相机底图。
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        if (released) return
        val buffer = frame.size
        if (buffer.width <= 0 || buffer.height <= 0) return
        val rotation = ((frame.rotationDegrees % 360) + 360) % 360
        val crop = frame.cropRect
        val geometry = WatermarkFrameGeometry.create(
            bufferWidth = buffer.width,
            bufferHeight = buffer.height,
            cropLeft = crop.left,
            cropTop = crop.top,
            cropRight = crop.right,
            cropBottom = crop.bottom,
            rotationDegrees = rotation,
            mirroring = frame.isMirroring,
        )
        if (geometry.displayWidth <= 0 || geometry.displayHeight <= 0) return

        val key = buildString {
            append(geometry.displayWidth).append('x').append(geometry.displayHeight)
            append('|').append(model.hashCode())
        }
        val bitmap = if (key == cachedKey && cachedBitmap != null) {
            cachedBitmap!!
        } else {
            val fresh = Bitmap.createBitmap(
                geometry.displayWidth,
                geometry.displayHeight,
                Bitmap.Config.ARGB_8888,
            )
            drawInArea(
                Canvas(fresh),
                model,
                RectF(
                    0f,
                    0f,
                    geometry.displayWidth.toFloat(),
                    geometry.displayHeight.toFloat(),
                ),
                constrainToTargetAspect = false,
            )
            cachedBitmap?.recycle()
            cachedBitmap = fresh
            cachedKey = key
            fresh
        }

        val matrix = Matrix()
        if (!matrix.setPolyToPoly(
            geometry.sourcePoints(),
            0,
            geometry.destinationPoints(),
            0,
            3,
        )) {
            return
        }

        if (DEBUG_LOG.compareAndSet(false, true)) {
            android.util.Log.d(
                "WMWatermark",
                "buffer=" + buffer.width + "x" + buffer.height +
                    " rot=" + rotation +
                    " display=" + geometry.displayWidth + "x" + geometry.displayHeight +
                    " crop=" + frame.cropRect +
                    " mirror=" + frame.isMirroring,
            )
        }

        canvas.drawBitmap(bitmap, matrix, null)
    }

    /** 释放缓存位图；会话结束时调用，避免长时间占用内存。 */
    @Synchronized
    fun release(sessionGeneration: Int) {
        // 过期会话的释放任务直接忽略：新会话可能已经在用这份缓存了
        if (sessionGeneration != generation) return
        released = true
        cachedBitmap?.recycle()
        cachedBitmap = null
        cachedKey = null
    }

    private fun drawInArea(
        canvas: Canvas,
        model: WatermarkModel,
        area: RectF,
        constrainToTargetAspect: Boolean = true,
    ) {
        if (area.width() <= 0f || area.height() <= 0f) return

        val rows = buildRows(model)
        if (rows.isEmpty() && model.unitTitle.isBlank() && model.department.isBlank()) return

        // 相机缓冲区可能是 4:3，而成片按 16:9 裁剪；直接在缓冲区底部画，
        // 预览里完整的卡片到了照片里会被裁掉下半截。这里先把 16:9 安全区
        // 算出来，卡片贴着安全区底部，照片、视频和预览都能完整看到。
        val safe = if (constrainToTargetAspect) safeArea(area) else area

        var metrics = measureCard(rows, model, safe.width() * CARD_WIDTH_RATIO)
        // 所有字段都开、地址和天气又换行时卡片会明显变高；按可见高度兜底
        // 等比缩小，保证信息完整落在画面内，不被上沿或提示条截断。
        val maxCardHeight = safe.height() * MAX_CARD_HEIGHT_RATIO
        if (metrics.cardHeight > maxCardHeight && metrics.cardHeight > 0f) {
            metrics = measureCard(
                rows,
                model,
                safe.width() * CARD_WIDTH_RATIO * (maxCardHeight / metrics.cardHeight),
            )
        }

        val cardWidth = metrics.cardWidth
        val marginLeft = safe.width() * MARGIN_LEFT_RATIO
        val marginBottom = safe.width() * MARGIN_BOTTOM_RATIO
        val left = (safe.left + marginLeft).coerceAtLeast(area.left)
        val top = safe.bottom - marginBottom - metrics.cardHeight
        val card = RectF(left, top, left + cardWidth, top + metrics.cardHeight)

        drawShadow(canvas, card, cardWidth)
        drawHeader(canvas, model, card, cardWidth, metrics.headerHeight)
        drawBodyBackground(canvas, card, cardWidth, metrics)
        drawBody(canvas, metrics, card)
        if (metrics.footerHeight > 0f) {
            drawFooter(canvas, model, card, metrics)
        }
    }

    /** 取画面内居中的 16:9 区域：照片、录像与预览三者都能看到的范围。 */
    private fun safeArea(area: RectF): RectF {
        val aspect = area.width() / area.height()
        return if (aspect > TARGET_ASPECT) {
            val width = area.height() * TARGET_ASPECT
            RectF(
                area.centerX() - width / 2f,
                area.top,
                area.centerX() + width / 2f,
                area.bottom,
            )
        } else {
            val height = area.width() / TARGET_ASPECT
            RectF(
                area.left,
                area.centerY() - height / 2f,
                area.right,
                area.centerY() + height / 2f,
            )
        }
    }

    /**
     * 先按卡片宽度算出字号并真实换行，再按实际行数定行高。
     *
     * 旧版用字符数阈值预判两行（天气 >18 字、地址 >20 字），即使文字明明
     * 放得下一行也把行高翻倍，卡片被撑高、信息反而更容易被裁。
     */
    private fun measureCard(
        rows: List<Row>,
        model: WatermarkModel,
        requestedWidth: Float,
    ): CardMetrics {
        val cardWidth = requestedWidth.coerceAtLeast(1f)
        val headerHeight = cardWidth * HEADER_RATIO
        val rowHeight = cardWidth * ROW_RATIO
        val valueFont = rowHeight * 0.58f
        val valuePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TEXT_MAIN
            textSize = valueFont
            typeface = Typeface.DEFAULT
        }
        val maxValueWidth = cardWidth * (1f - VALUE_LEFT_RATIO - VALUE_RIGHT_PADDING_RATIO)
        val layouts = rows.map { row ->
            val lines = wrapText(row.value, valuePaint, maxValueWidth, row.maxLines)
            RowLayout(row, lines, rowHeight * lines.size)
        }
        val bodyHeight = layouts.sumOf { it.height.toDouble() }.toFloat()
        val footerHeight = if (model.department.isBlank()) 0f else cardWidth * FOOTER_RATIO
        return CardMetrics(
            cardWidth = cardWidth,
            headerHeight = headerHeight,
            rowHeight = rowHeight,
            bodyHeight = bodyHeight,
            footerHeight = footerHeight,
            cardHeight = headerHeight + bodyHeight + footerHeight,
            rows = layouts,
        )
    }

    private fun buildRows(model: WatermarkModel): List<Row> {
        val rows = mutableListOf<Row>()
        if (model.showTime) rows.add(Row("拍摄时间", model.dateText))
        if (model.showWeather && model.weather.isNotBlank()) {
            rows.add(Row("天气", model.weather, maxLines = 2))
        }
        if (model.showLocation && model.address.isNotBlank()) {
            rows.add(Row("地点", model.address, maxLines = 2))
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

    /** 卡片投影；卡面本身是半透明的，投影只负责和背景拉开层次。 */
    private fun drawShadow(canvas: Canvas, card: RectF, cardWidth: Float) {
        val radius = cardWidth * CORNER_RATIO
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(52, 0, 0, 0)
        }
        canvas.drawRoundRect(
            RectF(
                card.left + cardWidth * 0.004f,
                card.top + cardWidth * 0.006f,
                card.right,
                card.bottom,
            ),
            radius,
            radius,
            shadow,
        )
    }

    private fun drawHeader(
        canvas: Canvas,
        model: WatermarkModel,
        card: RectF,
        cardWidth: Float,
        headerHeight: Float,
    ) {
        val radius = cardWidth * CORNER_RATIO
        val clip = Path().apply {
            addRoundRect(
                RectF(card.left, card.top, card.right, card.top + headerHeight),
                floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f),
                Path.Direction.CW,
            )
        }
        canvas.save()
        canvas.clipPath(clip)
        canvas.drawRect(
            card.left,
            card.top,
            card.right,
            card.top + headerHeight,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BLUE },
        )
        canvas.restore()

        val emblemSize = headerHeight * 0.70f
        val emblemLeft = card.left + headerHeight * 0.10f
        val emblemTop = card.top + (headerHeight - emblemSize) / 2f
        if (model.showLogo) {
            drawEmblem(
                canvas,
                RectF(emblemLeft, emblemTop, emblemLeft + emblemSize, emblemTop + emblemSize),
            )
        }

        val textLeft = if (model.showLogo) {
            // 白底队徽比徽标本体大 5%，留一点余量后再起排
            emblemLeft + emblemSize * 1.10f + cardWidth * 0.020f
        } else {
            card.left + cardWidth * 0.040f
        }
        val textRight = card.right - cardWidth * 0.025f
        val available = (textRight - textLeft).coerceAtLeast(0f)
        if (available <= 0f) return

        // 抬头字号与正文同级：旧版 0.40×抬头高度会让 13 个字的单位名
        // 撑满整条蓝带，既压住队徽，也和下方信息头重脚轻。
        val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TITLE_TEXT
            textSize = min(cardWidth * 0.046f, headerHeight * 0.34f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        val title = model.unitTitle.ifBlank { "现场影像" }
        val measured = titlePaint.measureText(title)
        val shown = if (measured > available) {
            TextUtils.ellipsize(title, titlePaint, available, TextUtils.TruncateAt.END).toString()
        } else {
            title
        }
        val shownWidth = if (shown === title) measured else titlePaint.measureText(shown)
        // 文字在「队徽右侧到卡片右缘」之间居中，与参考图的视觉重心一致
        val x = if (measured > available) textLeft else textLeft + (available - shownWidth) / 2f
        val baseline = card.top + headerHeight / 2f -
            (titlePaint.ascent() + titlePaint.descent()) / 2f
        canvas.drawText(shown, x, baseline, titlePaint)
    }

    /** 信息区半透明白底；抬头和底条自己带蓝底，不能先铺一层白再叠蓝，否则透明度叠加会发闷。 */
    private fun drawBodyBackground(canvas: Canvas, card: RectF, cardWidth: Float, metrics: CardMetrics) {
        val radius = cardWidth * CORNER_RATIO
        val top = card.top + metrics.headerHeight
        val bottom = card.bottom - metrics.footerHeight
        if (bottom <= top) return
        val bottomRadius = if (metrics.footerHeight > 0f) 0f else radius
        val path = Path().apply {
            addRoundRect(
                RectF(card.left, top, card.right, bottom),
                floatArrayOf(
                    0f, 0f,
                    0f, 0f,
                    bottomRadius, bottomRadius,
                    bottomRadius, bottomRadius,
                ),
                Path.Direction.CW,
            )
        }
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CARD_BG })
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
        // 白色圆角底衬托，避免蓝色队徽与半透明蓝色抬头条混在一起
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        val padding = box.width() * 0.05f
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

    private fun drawBody(canvas: Canvas, metrics: CardMetrics, card: RectF) {
        val layouts = metrics.rows
        if (layouts.isEmpty()) return
        val cardWidth = metrics.cardWidth
        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TEXT_MAIN
            textSize = metrics.rowHeight * 0.58f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val valuePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TEXT_MAIN
            textSize = metrics.rowHeight * 0.58f
            typeface = Typeface.DEFAULT
        }
        val dividerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = DIVIDER
            strokeWidth = (cardWidth * 0.0022f).coerceAtLeast(1f)
        }

        var cursor = card.top + metrics.headerHeight
        layouts.forEachIndexed { index, layout ->
            val centerY = cursor + layout.height / 2f
            drawLabel(canvas, layout.row.label, card, cardWidth, centerY, labelPaint)

            val baseline = centerY - (labelPaint.ascent() + labelPaint.descent()) / 2f
            canvas.drawText("：", card.left + cardWidth * COLON_RATIO, baseline, labelPaint)

            // 数值：测量的行数与绘制保持一致，多行时整块垂直居中
            val valueLineHeight = valuePaint.textSize * 1.20f
            val valueBlockHeight = valueLineHeight * layout.lines.size
            var valueY = centerY - valueBlockHeight / 2f + valuePaint.textSize
            val valueLeft = card.left + cardWidth * VALUE_LEFT_RATIO
            layout.lines.forEach { line ->
                canvas.drawText(line, valueLeft, valueY, valuePaint)
                valueY += valueLineHeight
            }

            cursor += layout.height
            if (index < layouts.size - 1) {
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

    private fun drawFooter(canvas: Canvas, model: WatermarkModel, card: RectF, metrics: CardMetrics) {
        val cardWidth = metrics.cardWidth
        val footerHeight = metrics.footerHeight
        if (footerHeight <= 0f) return

        // bodyBottom 是相对卡片顶部的偏移，必须加上 card.top 才是画布坐标。
        val top = card.top + metrics.headerHeight + metrics.bodyHeight
        val radius = cardWidth * CORNER_RATIO
        val clip = Path().apply {
            addRoundRect(
                RectF(card.left, top, card.right, card.bottom),
                floatArrayOf(0f, 0f, 0f, 0f, radius, radius, radius, radius),
                Path.Direction.CW,
            )
        }
        canvas.save()
        canvas.clipPath(clip)
        canvas.drawRect(
            card.left,
            top,
            card.right,
            card.bottom,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BLUE },
        )
        canvas.restore()

        // 底条与信息行共用同一套标签列、冒号和数值起点：字号和正文同级，
        // 不再像旧版那样只有正文的 0.52，远看几乎糊成一条线。
        val font = min(footerHeight * 0.70f, metrics.rowHeight * 0.58f)
        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = FOOTER_LABEL
            textSize = font
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        val valuePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = FOOTER_VALUE
            textSize = font
            typeface = Typeface.DEFAULT
        }
        val centerY = top + footerHeight / 2f
        drawLabel(canvas, "拍摄单位", card, cardWidth, centerY, labelPaint)

        val baseline = centerY - (labelPaint.ascent() + labelPaint.descent()) / 2f
        canvas.drawText("：", card.left + cardWidth * COLON_RATIO, baseline, labelPaint)

        val valueLeft = card.left + cardWidth * VALUE_LEFT_RATIO
        val available = card.right - valueLeft - cardWidth * VALUE_RIGHT_PADDING_RATIO
        if (available <= 0f) return
        val shown = TextUtils.ellipsize(
            model.department,
            valuePaint,
            available,
            TextUtils.TruncateAt.END,
        ).toString()
        canvas.drawText(shown, valueLeft, baseline, valuePaint)
    }

    /** 标签在固定列内按字符分散对齐（「拍 摄 时 间」「天    气」），单行居中。 */
    private fun drawLabel(
        canvas: Canvas,
        label: String,
        card: RectF,
        cardWidth: Float,
        centerY: Float,
        paint: TextPaint,
    ) {
        if (label.isEmpty()) return
        val left = card.left + cardWidth * LABEL_LEFT_RATIO
        val right = card.left + cardWidth * LABEL_RIGHT_RATIO
        val baseline = centerY - (paint.ascent() + paint.descent()) / 2f
        val chars = label.toCharArray()
        if (chars.size == 1) {
            val width = paint.measureText(label)
            canvas.drawText(label, (left + right - width) / 2f, baseline, paint)
            return
        }
        val widths = FloatArray(chars.size) { paint.measureText(chars[it].toString()) }
        val total = widths.sum()
        val gap = (right - left - total) / (chars.size - 1)
        if (gap < 0f) {
            // 标签本身超长时退回左对齐并省略，避免压到数值区
            val shown = TextUtils.ellipsize(
                label,
                paint,
                right - left,
                TextUtils.TruncateAt.END,
            ).toString()
            canvas.drawText(shown, left, baseline, paint)
            return
        }
        var x = left
        chars.forEachIndexed { index, char ->
            canvas.drawText(char.toString(), x, baseline, paint)
            x += widths[index] + gap
        }
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
