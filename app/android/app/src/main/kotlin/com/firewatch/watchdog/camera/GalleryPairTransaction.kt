package com.firewatch.watchdog.camera

/**
 * 相册成对写入事务：只发布本次新建的条目，任一步失败时逆序删除本次新建项。
 *
 * 这个对象不依赖 Android API，便于 JVM 测试覆盖回滚顺序和幂等复用分支。
 */
internal object GalleryPairTransaction {
    data class Prepared<T>(
        val value: T,
        val created: Boolean,
    )

    fun <T> save(
        prepareWatermarked: () -> Prepared<T>,
        prepareSource: () -> Prepared<T>,
        publish: (T) -> Unit,
        rollback: (T) -> Unit,
    ): Pair<T, T> {
        val created = mutableListOf<T>()
        try {
            val watermarked = prepareWatermarked()
            if (watermarked.created) created += watermarked.value
            val source = prepareSource()
            if (source.created) created += source.value

            created.forEach(publish)
            return watermarked.value to source.value
        } catch (error: Throwable) {
            created.asReversed().forEach { entry ->
                runCatching { rollback(entry) }
            }
            throw error
        }
    }
}
