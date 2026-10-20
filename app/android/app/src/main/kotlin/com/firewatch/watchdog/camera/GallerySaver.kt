package com.firewatch.watchdog.camera

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * 把本机拍摄文件导出到系统相册。
 *
 * 成对保存采用“先准备两份、再一起发布”的策略；任一步失败都会删除本次新建
 * 的相册项，避免用户看到只有水印版或只有母版的半套结果。
 */
object GallerySaver {
    private const val ALBUM = "火场智控"

    data class SavedPair(
        val watermarked: Uri,
        val source: Uri,
    )

    /** Android 9 及以下写公共相册需要存储权限。 */
    fun needsLegacyStoragePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    fun save(context: Context, source: File): Uri {
        require(source.isFile) { "文件不存在" }
        val video = source.extension.equals("mp4", ignoreCase = true)
        val displayName = GalleryNaming.displayName(source, video, true)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val (uri, created) = prepareMediaStore(
                context,
                source,
                video,
                displayName,
            )
            if (created) {
                try {
                    publishMediaStore(context, uri)
                } catch (error: Exception) {
                    runCatching { context.contentResolver.delete(uri, null, null) }
                    throw error
                }
            }
            uri
        } else {
            prepareLegacyFile(context, source, video, displayName).first
        }
    }

    fun savePair(context: Context, watermarked: File, source: File): SavedPair {
        require(watermarked.isFile) { "带水印文件不存在" }
        require(source.isFile) { "无水印母版不存在" }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            savePairMediaStore(context, watermarked, source)
        } else {
            savePairLegacy(context, watermarked, source)
        }
    }

    private fun savePairMediaStore(
        context: Context,
        watermarked: File,
        source: File,
    ): SavedPair {
        val resolver = context.contentResolver
        val wmVideo = watermarked.extension.equals("mp4", ignoreCase = true)
        val sourceVideo = source.extension.equals("mp4", ignoreCase = true)
        val pair = GalleryPairTransaction.save(
            prepareWatermarked = {
                prepareMediaStore(
                    context,
                    watermarked,
                    wmVideo,
                    GalleryNaming.displayName(watermarked, wmVideo, true),
                ).let { GalleryPairTransaction.Prepared(it.first, it.second) }
            },
            prepareSource = {
                prepareMediaStore(
                    context,
                    source,
                    sourceVideo,
                    GalleryNaming.displayName(source, sourceVideo, false),
                ).let { GalleryPairTransaction.Prepared(it.first, it.second) }
            },
            publish = { uri -> publishMediaStore(context, uri) },
            rollback = { uri -> resolver.delete(uri, null, null) },
        )
        return SavedPair(pair.first, pair.second)
    }

    private fun publishMediaStore(context: Context, uri: Uri) {
        val published = context.contentResolver.update(
            uri,
            ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            },
            null,
            null,
        )
        check(published == 1) { "相册文件发布失败" }
    }

    private fun prepareMediaStore(
        context: Context,
        source: File,
        video: Boolean,
        displayName: String,
    ): Pair<Uri, Boolean> {
        val resolver = context.contentResolver
        val collection = collection(video)
        val relativePath = albumPath(video)
        val selection = buildString {
            append(MediaStore.MediaColumns.DISPLAY_NAME).append("=? AND ")
            append(MediaStore.MediaColumns.RELATIVE_PATH).append("=?")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                append(" AND ").append(MediaStore.MediaColumns.IS_PENDING).append("=0")
            }
        }
        val existing = runCatching {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                selection,
                arrayOf(displayName, "$relativePath/"),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        }.getOrNull()
        if (existing != null) {
            return Uri.withAppendedPath(collection, existing.toString()) to false
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType(video))
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: error("系统相册不可写")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("无法写入系统相册")
            return uri to true
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun savePairLegacy(
        context: Context,
        watermarked: File,
        source: File,
    ): SavedPair {
        val wmVideo = watermarked.extension.equals("mp4", ignoreCase = true)
        val sourceVideo = source.extension.equals("mp4", ignoreCase = true)
        val wm = prepareLegacyFile(
            context,
            watermarked,
            wmVideo,
            GalleryNaming.displayName(watermarked, wmVideo, true),
        )
        val raw = try {
            prepareLegacyFile(
                context,
                source,
                sourceVideo,
                GalleryNaming.displayName(source, sourceVideo, false),
            )
        } catch (error: Exception) {
            if (wm.second) runCatching { File(wm.first.path!!).delete() }
            throw error
        }
        if (wm.second) {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(wm.first.path),
                arrayOf(mimeType(wmVideo)),
                null,
            )
        }
        if (raw.second) {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(raw.first.path),
                arrayOf(mimeType(sourceVideo)),
                null,
            )
        }
        return SavedPair(wm.first, raw.first)
    }

    @Suppress("DEPRECATION")
    private fun prepareLegacyFile(
        context: Context,
        source: File,
        video: Boolean,
        displayName: String,
    ): Pair<Uri, Boolean> {
        val base = Environment.getExternalStoragePublicDirectory(
            if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES,
        )
        val dir = File(base, ALBUM).apply { mkdirs() }
        val target = File(dir, displayName)
        if (target.isFile && target.length() == source.length()) {
            return Uri.fromFile(target) to false
        }
        val partial = File(dir, "$displayName.part").apply {
            if (exists()) delete()
        }
        try {
            source.inputStream().use { input ->
                partial.outputStream().use { output -> input.copyTo(output) }
            }
            check(partial.length() == source.length()) { "相册文件写入不完整" }
            if (target.exists()) target.delete()
            check(partial.renameTo(target)) { "相册文件落盘失败" }
            return Uri.fromFile(target) to true
        } catch (error: Exception) {
            partial.delete()
            throw error
        }
    }

    private fun collection(video: Boolean): Uri =
        if (video) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }

    private fun albumPath(video: Boolean): String =
        (if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) +
            "/" + ALBUM

    private fun mimeType(video: Boolean): String =
        if (video) "video/mp4" else "image/jpeg"
}
