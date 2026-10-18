package com.firewatch.watchdog.camera

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * 水印内容模型。
 *
 * 关键约束：拍摄开始时冻结一次，录制过程中不再变化。否则视频里的时间会一路跳动、
 * 地址会在移动时不断刷新，作为现场证据反而不可信。
 *
 * 字段刻意与账号解耦：抬头、拍摄部门都可以单独配置，不强制等于登录身份。
 */
data class WatermarkModel(
    val unitTitle: String = "",
    val department: String = "",
    val actorName: String = "",
    val address: String = "",
    val weather: String = "",
    val latitude: Double? = null,
    val longitude: Double? = null,
    val timestampMs: Long = System.currentTimeMillis(),
    val showTime: Boolean = true,
    val showWeather: Boolean = true,
    val showLocation: Boolean = true,
    val showCoordinates: Boolean = true,
    val showLogo: Boolean = true,
) {
    /** 2026.10.18 星期日 08:39 —— 与现场水印相机惯例一致，带星期便于事后核对。 */
    val dateText: String
        get() {
            val date = SimpleDateFormat("yyyy.MM.dd", Locale.CHINA).format(Date(timestampMs))
            val time = SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(timestampMs))
            return "$date ${weekdayText(timestampMs)} $time"
        }

    val coordinateText: String
        get() {
            val lat = latitude ?: return ""
            val lon = longitude ?: return ""
            val ns = if (lat >= 0) "北纬" else "南纬"
            val ew = if (lon >= 0) "东经" else "西经"
            return "$ew ${dms(lon)}\n$ns ${dms(lat)}"
        }

    fun withFrozenTime(now: Long = System.currentTimeMillis()): WatermarkModel =
        copy(timestampMs = now)

    companion object {
        private val WEEKDAYS = arrayOf("星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六")

        fun weekdayText(timestampMs: Long): String {
            val calendar = Calendar.getInstance().apply { timeInMillis = timestampMs }
            return WEEKDAYS[calendar.get(Calendar.DAY_OF_WEEK) - 1]
        }

        /** 十进制度 → 度分，例如 118.3666 → 118°22′。 */
        fun dms(value: Double): String {
            val abs = kotlin.math.abs(value)
            val degrees = abs.toInt()
            val minutes = ((abs - degrees) * 60).toInt()
            return "$degrees°$minutes′"
        }

        fun fromMap(map: Map<*, *>?): WatermarkModel {
            if (map == null) return WatermarkModel()
            fun str(key: String): String = (map[key] as? String)?.trim().orEmpty()
            fun flag(key: String, fallback: Boolean = true): Boolean =
                (map[key] as? Boolean) ?: fallback

            return WatermarkModel(
                unitTitle = str("unitTitle"),
                department = str("department"),
                actorName = str("actorName"),
                address = str("address"),
                weather = str("weather"),
                latitude = (map["latitude"] as? Number)?.toDouble(),
                longitude = (map["longitude"] as? Number)?.toDouble(),
                timestampMs = (map["timestampMs"] as? Number)?.toLong()
                    ?: System.currentTimeMillis(),
                showTime = flag("showTime"),
                showWeather = flag("showWeather"),
                showLocation = flag("showLocation"),
                showCoordinates = flag("showCoordinates"),
                showLogo = flag("showLogo"),
            )
        }
    }
}
