package com.firewatch.watchdog.camera

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * 从已录制的水印视频中派生出可分析的数据：
 * - 音轨 → 16kHz 单声道 16bit WAV（喂给本地 sherpa-onnx 识别）
 * - 关键帧 → 若干张 JPEG（供 AI 视觉分析；不把整段视频传上网）
 *
 * 全部在本机完成，视频文件本身不出设备。
 */
object MediaDerivatives {

    private const val TARGET_SAMPLE_RATE = 16_000

    /** 抽取音轨并转成 16k 单声道 WAV。失败返回 null，不抛出。 */
    fun extractWav(source: File, target: File): File? {
        if (!source.isFile || source.length() <= 0L) return null
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        return try {
            extractor.setDataSource(source.absolutePath)
            val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index)
                    .getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: return null

            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val sourceSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcm = ArrayList<Short>(sourceSampleRate * 60)
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (!inputDone) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val buffer = codec.getInputBuffer(inputIndex) ?: continue
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                when {
                    outputIndex >= 0 -> {
                        val out = codec.getOutputBuffer(outputIndex)
                        if (out != null && bufferInfo.size > 0) {
                            out.position(bufferInfo.offset)
                            out.limit(bufferInfo.offset + bufferInfo.size)
                            val shorts = out.order(ByteOrder.LITTLE_ENDIAN)
                                .asShortBuffer()
                            while (shorts.hasRemaining()) pcm.add(shorts.get())
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                    outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER ||
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                }
            }

            if (pcm.isEmpty()) return null
            val mono = toMono(pcm, channelCount)
            val resampled = resample(mono, sourceSampleRate, TARGET_SAMPLE_RATE)
            if (resampled.isEmpty()) return null
            writeWav(target, resampled, TARGET_SAMPLE_RATE)
            target
        } catch (_: Exception) {
            target.delete()
            null
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }

    /** 均匀抽取 count 帧（首尾各留 10% 余量，避开片头片尾黑帧）。 */
    fun extractFrames(source: File, targetDir: File, count: Int = 3): List<File> {
        if (!source.isFile) return emptyList()
        val safeCount = count.coerceIn(1, 6)
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(source.absolutePath)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            if (durationMs <= 0L) return emptyList()
            targetDir.mkdirs()

            val files = mutableListOf<File>()
            repeat(safeCount) { index ->
                val fraction = if (safeCount == 1) 0.5 else 0.1 + 0.8 * index / (safeCount - 1)
                val timeUs = (durationMs * fraction * 1000).toLong()
                val bitmap: Bitmap? = retriever.getFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                if (bitmap != null) {
                    val file = File(targetDir, "frame_${index}_${timeUs / 1000}.jpg")
                    file.outputStream().use { out ->
                        // 缩到 1280 宽，既够模型看清，又不至于单帧过大
                        val scaled = scaleDown(bitmap, 1280)
                        scaled.compress(Bitmap.CompressFormat.JPEG, 82, out)
                        if (scaled !== bitmap) scaled.recycle()
                    }
                    bitmap.recycle()
                    files.add(file)
                }
            }
            files
        } catch (_: Exception) {
            emptyList()
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun scaleDown(bitmap: Bitmap, maxWidth: Int): Bitmap {
        if (bitmap.width <= maxWidth) return bitmap
        val ratio = maxWidth.toFloat() / bitmap.width
        return Bitmap.createScaledBitmap(
            bitmap,
            maxWidth,
            (bitmap.height * ratio).roundToInt().coerceAtLeast(1),
            true,
        )
    }

    private fun toMono(samples: List<Short>, channels: Int): ShortArray {
        if (channels <= 1) return ShortArray(samples.size) { samples[it] }
        val frames = samples.size / channels
        return ShortArray(frames) { frame ->
            var sum = 0
            for (c in 0 until channels) sum += samples[frame * channels + c]
            (sum / channels).toShort()
        }
    }

    /** 线性插值重采样；语音识别对音质要求不高，够用且无额外依赖。 */
    private fun resample(input: ShortArray, from: Int, to: Int): ShortArray {
        if (from == to || input.isEmpty()) return input
        val ratio = from.toDouble() / to
        val length = (input.size / ratio).toInt()
        if (length <= 0) return ShortArray(0)
        return ShortArray(length) { index ->
            val position = index * ratio
            val left = position.toInt().coerceIn(0, input.size - 1)
            val right = (left + 1).coerceAtMost(input.size - 1)
            val weight = position - left
            (input[left] * (1 - weight) + input[right] * weight).roundToInt().toShort()
        }
    }

    private fun writeWav(target: File, samples: ShortArray, sampleRate: Int) {
        val dataSize = samples.size * 2
        RandomAccessFile(target, "rw").use { file ->
            file.setLength(0)
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + dataSize)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)
            header.putShort(1)
            header.putShort(1)
            header.putInt(sampleRate)
            header.putInt(sampleRate * 2)
            header.putShort(2)
            header.putShort(16)
            header.put("data".toByteArray())
            header.putInt(dataSize)
            file.write(header.array())
            val body = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
            samples.forEach { body.putShort(it) }
            file.write(body.array())
        }
    }
}
