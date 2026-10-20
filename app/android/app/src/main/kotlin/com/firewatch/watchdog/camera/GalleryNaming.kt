package com.firewatch.watchdog.camera

import java.io.File

/** 相册命名只依赖拍摄文件名，便于无设备 JVM 测试幂等命名规则。 */
internal object GalleryNaming {
    fun displayName(source: File, video: Boolean, watermarked: Boolean): String {
        val stem = source.nameWithoutExtension
            .removeSuffix("_WM")
            .removePrefix("SRC_")
        val suffix = if (watermarked) "带水印" else "无水印"
        val extension = if (video) "mp4" else "jpg"
        return "${stem}_$suffix.$extension"
    }
}
