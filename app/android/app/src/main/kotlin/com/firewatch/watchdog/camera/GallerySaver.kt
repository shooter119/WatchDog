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
 * 把水印相机拍下的文件导出到系统相册。
 *
 * 应用内文件仍保留在私有目录（「现场资料」用），相册里再留一份，
 * 方便现场结束后直接用手机相册翻看、发给别人或长期保存。
 *
 * 同一次拍摄重复点「保存到相册」不会产生多份：先按 DISPLAY_NAME 查
 * MediaStore，已存在就直接复用原 Uri。
 */
object GallerySaver {
    private const val ALBUM = "火场智控"

    /** Android 9 及以下写公共相册需要存储权限。 */
    fun needsLegacyStoragePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    fun save(context: Context, source: File): Uri {
        require(source.isFile) { "文件不存在" }
        val video = source.extension.equals("mp4", ignoreCase = true)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveToMediaStore(context, source, video)
        } else {
            saveToPublicDirectory(context, source, video)
        }
    }

    private fun saveToMediaStore(context: Context, source: File, video: Boolean): Uri {
        val resolver = context.contentResolver
        val collection = if (video) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relativePath = albumPath(video)

        // 已导出过就复用，避免同一张照片在相册里出现多份。
        val existing = runCatching {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND " +
                    "${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                arrayOf(source.name, "$relativePath/"),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        }.getOrNull()
        if (existing != null) {
            return Uri.withAppendedPath(collection, existing.toString())
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
            put(MediaStore.MediaColumns.MIME_TYPE, if (video) "video/mp4" else "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: error("系统相册不可写")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("无法写入系统相册")
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            return uri
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveToPublicDirectory(context: Context, source: File, video: Boolean): Uri {
        val base = Environment.getExternalStoragePublicDirectory(
            if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES,
        )
        val dir = File(base, ALBUM).apply { mkdirs() }
        val target = File(dir, source.name)
        if (!target.isFile || target.length() != source.length()) {
            source.inputStream().use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }
        MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), null, null)
        return Uri.fromFile(target)
    }

    private fun albumPath(video: Boolean): String =
        (if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/" + ALBUM
}
