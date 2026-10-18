package com.firewatch.watchdog.camera

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 水印内容模型。
 *
 * 关键约束：拍摄开始时冻结一次，录制过程中不再变化。否则视频里的时间会一路跳动、
 * 地址会在移动时不断刷新，作为现场证据反而不可信。
 */
data class WatermarkModel(
    val unitName: String = "",
    val incidentName: String = "",
    val address: String = "",
    val weather: String = "",
    val actorName: String = "",
    val timestampMs: Long = System.currentTimeMillis(),
) {
    /** 渲染时使用的固定时间文本，避免每帧重新格式化。 */
    val timeText: String
        get() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.CHINA).format(Date(timestampMs))

    fun withFrozenTime(now: Long = System.currentTimeMillis()): WatermarkModel = copy(timestampMs = now)

    companion object {
        fun fromMap(map: Map<*, *>?): WatermarkModel {
            if (map == null) return WatermarkModel()
            fun str(key: String): String = (map[key] as? String)?.trim().orEmpty()
            val ts = (map["timestampMs"] as? Number)?.toLong() ?: System.currentTimeMillis()
            return WatermarkModel(
                unitName = str("unitName"),
                incidentName = str("incidentName"),
                address = str("address"),
                weather = str("weather"),
                actorName = str("actorName"),
                timestampMs = ts,
            )
        }
    }
}
