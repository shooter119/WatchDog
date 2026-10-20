package com.firewatch.watchdog.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix as BitmapMatrix
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.Looper
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * 从 CameraX 输出的无水印母版生成带水印成片。
 *
 * 照片保持原分辨率写 JPEG；视频用硬件 MediaCodec 做一次视频转码，原音轨
 * 压缩样本直接复用。临时文件全部以 .part 结尾，成功后原子改名。
 */
object MediaWatermarkProcessor {
    fun render(
        source: File,
        watermark: WatermarkModel,
        taskId: String,
        onProgress: (Double) -> Unit,
    ): File {
        require(source.isFile) { "找不到拍摄母版" }
        return when (source.extension.lowercase()) {
            "jpg", "jpeg" -> renderPhoto(source, watermark, onProgress)
            "mp4" -> renderVideo(source, watermark, taskId, onProgress)
            else -> error("不支持的媒体格式：${source.extension}")
        }
    }

    private fun renderPhoto(
        source: File,
        watermark: WatermarkModel,
        onProgress: (Double) -> Unit,
    ): File {
        val decoded = BitmapFactory.decodeFile(source.absolutePath)
            ?: error("照片母版无法解码")
        val upright = applyExifOrientation(source, decoded)
        if (upright !== decoded) decoded.recycle()
        try {
            val mutable = if (upright.isMutable) {
                upright
            } else {
                upright.copy(Bitmap.Config.ARGB_8888, true).also { upright.recycle() }
            }
            WatermarkOverlay.drawMedia(
                Canvas(mutable),
                mutable.width,
                mutable.height,
                watermark,
            )
            val target = watermarkedFile(source)
            val partial = File(target.parentFile, "${target.name}.part").apply {
                parentFile?.mkdirs()
                if (exists()) delete()
            }
            partial.outputStream().use { output ->
                check(mutable.compress(Bitmap.CompressFormat.JPEG, 95, output)) {
                    "水印照片编码失败"
                }
            }
            mutable.recycle()
            onProgress(1.0)
            publishAtomically(partial, target)
            return target
        } catch (error: Exception) {
            if (!upright.isRecycled) upright.recycle()
            throw error
        }
    }

    private fun applyExifOrientation(source: File, bitmap: Bitmap): Bitmap {
        val orientation = runCatching {
            ExifInterface(source.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val matrix = BitmapMatrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
        }
        if (matrix.isIdentity) return bitmap
        return Bitmap.createBitmap(
            bitmap,
            0,
            0,
            bitmap.width,
            bitmap.height,
            matrix,
            true,
        )
    }

    private fun renderVideo(
        source: File,
        watermark: WatermarkModel,
        taskId: String,
        onProgress: (Double) -> Unit,
    ): File {
        val target = watermarkedFile(source)
        val partial = File(target.parentFile, "${target.name}.part").apply {
            parentFile?.mkdirs()
            if (exists()) delete()
        }
        try {
            VideoWatermarkEncoder(source, partial, watermark, taskId, onProgress).run()
            publishAtomically(partial, target)
            return target
        } catch (error: Exception) {
            partial.delete()
            throw error
        }
    }

    private fun watermarkedFile(source: File): File {
        val cleanStem = source.nameWithoutExtension.removePrefix("SRC_")
        return File(source.parentFile, "${cleanStem}_WM.${source.extension.lowercase()}")
    }

    private fun publishAtomically(partial: File, target: File) {
        check(partial.isFile && partial.length() > 0L) { "成片写入失败" }
        if (target.exists()) target.delete()
        check(partial.renameTo(target)) { "成片落盘失败" }
    }

    private class VideoWatermarkEncoder(
        private val source: File,
        private val target: File,
        private val watermark: WatermarkModel,
        private val taskId: String,
        private val onProgress: (Double) -> Unit,
    ) {
        private val sourceExtractor = MediaExtractor()
        private val audioExtractor = MediaExtractor()
        private var decoder: MediaCodec? = null
        private var encoder: MediaCodec? = null
        private var muxer: MediaMuxer? = null
        private var surfaceTexture: android.graphics.SurfaceTexture? = null
        private var decoderSurface: Surface? = null
        private var encoderInputSurface: Surface? = null
        private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        private var videoTrackIndex = -1
        private var audioTrackIndex = -1
        private var muxerStarted = false
        private var decoderTextureId = 0

        fun run() {
            try {
                sourceExtractor.setDataSource(source.absolutePath)
                val videoTrack = findTrack(sourceExtractor, "video/")
                check(videoTrack >= 0) { "视频母版没有画面轨道" }
                val videoFormat = sourceExtractor.getTrackFormat(videoTrack)
                sourceExtractor.selectTrack(videoTrack)

                val sourceWidth = videoFormat.getInteger(MediaFormat.KEY_WIDTH)
                val sourceHeight = videoFormat.getInteger(MediaFormat.KEY_HEIGHT)
                val rotation = videoRotation()
                val rotationSwap = rotation == 90 || rotation == 270
                val outputWidth = even(if (rotationSwap) sourceHeight else sourceWidth)
                val outputHeight = even(if (rotationSwap) sourceWidth else sourceHeight)
                check(outputWidth > 0 && outputHeight > 0) { "视频尺寸无效" }

                muxer = MediaMuxer(
                    target.absolutePath,
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
                )
                prepareAudioTrack()
                encoder = createEncoder(videoFormat, outputWidth, outputHeight)
                encoderInputSurface = encoder!!.createInputSurface()
                encoder!!.start()
                initEgl(encoderInputSurface!!)
                createSurfaceTexture(sourceWidth, sourceHeight)
                configureDecoder(videoFormat, decoderSurface!!)

                val watermarkBitmap = WatermarkOverlay.renderMediaOverlay(
                    outputWidth,
                    outputHeight,
                    watermark,
                )
                val gl = GlRenderer(outputWidth, outputHeight, rotation)
                try {
                    gl.setup(watermarkBitmap)
                    decodeRenderAndEncode(
                        decoder = decoder!!,
                        encoder = encoder!!,
                        gl = gl,
                        durationUs = videoDurationUs(videoFormat),
                    )
                } finally {
                    gl.release()
                    watermarkBitmap.recycle()
                }
                copyAudio()
                onProgress(1.0)
            } finally {
                release()
            }
        }

        private fun prepareAudioTrack() {
            audioExtractor.setDataSource(source.absolutePath)
            val audioTrack = findTrack(audioExtractor, "audio/")
            if (audioTrack >= 0) {
                val format = audioExtractor.getTrackFormat(audioTrack)
                audioExtractor.selectTrack(audioTrack)
                audioTrackIndex = muxer!!.addTrack(format)
            }
        }

        private fun createEncoder(
            sourceFormat: MediaFormat,
            width: Int,
            height: Int,
        ): MediaCodec {
            val format = MediaFormat.createVideoFormat("video/avc", width, height).apply {
                setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                )
                val sourceBitrate = runCatching {
                    sourceFormat.getInteger(MediaFormat.KEY_BIT_RATE)
                }.getOrDefault(width * height * 6)
                setInteger(
                    MediaFormat.KEY_BIT_RATE,
                    sourceBitrate.coerceIn(2_000_000, 24_000_000),
                )
                val frameRate = runCatching {
                    sourceFormat.getInteger(MediaFormat.KEY_FRAME_RATE)
                }.getOrDefault(30).coerceIn(20, 60)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            return MediaCodec.createEncoderByType("video/avc").apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
        }

        private fun configureDecoder(format: MediaFormat, outputSurface: Surface) {
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: error("视频编码格式缺失")
            decoder = MediaCodec.createDecoderByType(mime).apply {
                configure(format, outputSurface, null, 0)
                start()
            }
        }

        private fun createSurfaceTexture(width: Int, height: Int) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
            decoderTextureId = textures[0]
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            surfaceTexture = android.graphics.SurfaceTexture(textures[0]).apply {
                setDefaultBufferSize(width, height)
            }
            decoderSurface = Surface(surfaceTexture)
        }

        private fun initEgl(outputSurface: Surface) {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "EGL 显示初始化失败" }
            val versions = IntArray(2)
            check(EGL14.eglInitialize(eglDisplay, versions, 0, versions, 1)) {
                "EGL 初始化失败"
            }
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            val attributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE,
                EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE,
                8,
                EGL14.EGL_GREEN_SIZE,
                8,
                EGL14.EGL_BLUE_SIZE,
                8,
                EGL14.EGL_ALPHA_SIZE,
                8,
                EGL14.EGL_NONE,
            )
            check(
                EGL14.eglChooseConfig(
                    eglDisplay,
                    attributes,
                    0,
                    configs,
                    0,
                    configs.size,
                    count,
                    0,
                ) && count[0] > 0,
            ) { "找不到可用的 EGL 配置" }
            eglContext = EGL14.eglCreateContext(
                eglDisplay,
                configs[0],
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                0,
            )
            check(eglContext != EGL14.EGL_NO_CONTEXT) { "EGL 上下文创建失败" }
            eglSurface = EGL14.eglCreateWindowSurface(
                eglDisplay,
                configs[0],
                outputSurface,
                intArrayOf(EGL14.EGL_NONE),
                0,
            )
            check(eglSurface != EGL14.EGL_NO_SURFACE) { "EGL 输出表面创建失败" }
            check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                "EGL 上下文切换失败"
            }
        }

        private fun decodeRenderAndEncode(
            decoder: MediaCodec,
            encoder: MediaCodec,
            gl: GlRenderer,
            durationUs: Long,
        ) {
            val surfaceTexture = surfaceTexture ?: error("视频输出表面缺失")
            val frameGate = FrameGate()
            surfaceTexture.setOnFrameAvailableListener(
                { frameGate.signal() },
                Handler(Looper.myLooper() ?: Looper.getMainLooper()),
            )
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var firstPtsUs = -1L
            var lastProgress = -1.0

            while (!outputDone) {
                if (!inputDone) inputDone = feedDecoder(decoder)
                when (val outputIndex = decoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                    else -> if (outputIndex >= 0) {
                        val endOfStream =
                            info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (info.size > 0) {
                            frameGate.reset()
                            decoder.releaseOutputBuffer(outputIndex, true)
                            check(frameGate.await(5, TimeUnit.SECONDS)) {
                                "等待视频帧超时"
                            }
                            surfaceTexture.updateTexImage()
                            val framePtsUs = surfaceTexture.timestamp / 1_000L
                            if (firstPtsUs < 0L) firstPtsUs = framePtsUs
                            EGLExt.eglPresentationTimeANDROID(
                                eglDisplay,
                                eglSurface,
                                surfaceTexture.timestamp,
                            )
                            gl.render(surfaceTexture, decoderTextureId)
                            check(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
                                "视频帧提交失败"
                            }
                            drainEncoder(encoder, false)
                            if (durationUs > 0L) {
                                val progress = (
                                    (framePtsUs - firstPtsUs).toDouble() /
                                        durationUs.toDouble()
                                    ).coerceIn(0.0, 0.99)
                                if (progress - lastProgress >= 0.02) {
                                    lastProgress = progress
                                    onProgress(progress)
                                }
                            }
                        } else {
                            decoder.releaseOutputBuffer(outputIndex, false)
                        }
                        if (endOfStream) outputDone = true
                    }
                }
            }
            drainEncoder(encoder, true)
            surfaceTexture.setOnFrameAvailableListener(null)
        }

        private fun feedDecoder(decoder: MediaCodec): Boolean {
            val inputIndex = decoder.dequeueInputBuffer(10_000)
            if (inputIndex < 0) return false
            val buffer = decoder.getInputBuffer(inputIndex) ?: return false
            val size = sourceExtractor.readSampleData(buffer, 0)
            if (size < 0) {
                decoder.queueInputBuffer(
                    inputIndex,
                    0,
                    0,
                    0,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                return true
            }
            decoder.queueInputBuffer(
                inputIndex,
                0,
                size,
                sourceExtractor.sampleTime,
                sourceExtractor.sampleFlags,
            )
            sourceExtractor.advance()
            return false
        }

        private fun drainEncoder(encoder: MediaCodec, endOfStream: Boolean) {
            if (endOfStream) encoder.signalEndOfInputStream()
            val info = MediaCodec.BufferInfo()
            while (true) {
                when (val outputIndex = encoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (endOfStream) continue else return
                    }
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        check(!muxerStarted) { "视频轨道格式重复" }
                        videoTrackIndex = muxer!!.addTrack(encoder.outputFormat)
                        muxer!!.start()
                        muxerStarted = true
                    }
                    else -> if (outputIndex >= 0) {
                        val encoded = encoder.getOutputBuffer(outputIndex)
                        if (
                            info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        ) {
                            info.size = 0
                        }
                        if (encoded != null && info.size > 0) {
                            check(muxerStarted) { "视频轨道尚未启动" }
                            encoded.position(info.offset)
                            encoded.limit(info.offset + info.size)
                            muxer!!.writeSampleData(videoTrackIndex, encoded, info)
                        }
                        encoder.releaseOutputBuffer(outputIndex, false)
                        if (
                            info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        ) {
                            return
                        }
                    }
                }
            }
        }

        private fun copyAudio() {
            if (audioTrackIndex < 0) return
            val format = audioExtractor.getTrackFormat(
                findTrack(audioExtractor, "audio/"),
            )
            val maxSize = runCatching {
                format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            }.getOrDefault(256 * 1024)
            val buffer = ByteBuffer.allocateDirect(maxSize.coerceAtLeast(64 * 1024))
                .order(ByteOrder.nativeOrder())
            val info = MediaCodec.BufferInfo()
            while (true) {
                buffer.clear()
                val size = audioExtractor.readSampleData(buffer, 0)
                if (size < 0) break
                info.set(
                    0,
                    size,
                    audioExtractor.sampleTime,
                    audioExtractor.sampleFlags,
                )
                muxer!!.writeSampleData(audioTrackIndex, buffer, info)
                audioExtractor.advance()
            }
        }

        private fun videoDurationUs(format: MediaFormat): Long {
            runCatching {
                return format.getLong(MediaFormat.KEY_DURATION)
            }
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(source.absolutePath)
                val ms = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toLongOrNull() ?: 0L
                ms * 1000L
            } finally {
                runCatching { retriever.release() }
            }
        }

        private fun videoRotation(): Int {
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(source.absolutePath)
                val raw = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0
                ((raw % 360) + 360) % 360
            } finally {
                runCatching { retriever.release() }
            }
        }

        private fun findTrack(extractor: MediaExtractor, prefix: String): Int {
            for (index in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(index)
                    .getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith(prefix) == true) return index
            }
            return -1
        }

        private fun even(value: Int): Int {
            if (value <= 1) return value
            return if (value % 2 == 0) value else value - 1
        }

        fun release() {
            runCatching { surfaceTexture?.setOnFrameAvailableListener(null) }
            runCatching { surfaceTexture?.release() }
            runCatching { decoderSurface?.release() }
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { encoderInputSurface?.release() }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                runCatching {
                    EGL14.eglMakeCurrent(
                        eglDisplay,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_CONTEXT,
                    )
                }
                if (eglSurface != EGL14.EGL_NO_SURFACE) {
                    runCatching { EGL14.eglDestroySurface(eglDisplay, eglSurface) }
                }
                if (eglContext != EGL14.EGL_NO_CONTEXT) {
                    runCatching { EGL14.eglDestroyContext(eglDisplay, eglContext) }
                }
                runCatching { EGL14.eglTerminate(eglDisplay) }
            }
            runCatching { sourceExtractor.release() }
            runCatching { audioExtractor.release() }
            if (muxerStarted) runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
        }
    }

    private class FrameGate {
        private val lock = Object()
        private var signaled = false

        fun reset() = synchronized(lock) {
            signaled = false
        }

        fun signal() = synchronized(lock) {
            signaled = true
            lock.notifyAll()
        }

        fun await(timeout: Long, unit: TimeUnit): Boolean {
            val deadline = System.nanoTime() + unit.toNanos(timeout)
            synchronized(lock) {
                while (!signaled) {
                    val remaining = deadline - System.nanoTime()
                    if (remaining <= 0L) return false
                    val millis = remaining / 1_000_000L
                    val nanos = (remaining % 1_000_000L).toInt()
                    lock.wait(millis, nanos)
                }
                return true
            }
        }
    }

    private class GlRenderer(
        private val width: Int,
        private val height: Int,
        private val rotation: Int,
    ) {
        private val cameraProgram = createProgram(CAMERA_VERTEX_SHADER, CAMERA_FRAGMENT_SHADER)
        private val overlayProgram = createProgram(OVERLAY_VERTEX_SHADER, OVERLAY_FRAGMENT_SHADER)
        private val positionBuffer = floatBuffer(
            floatArrayOf(
                -1f, -1f,
                1f, -1f,
                -1f, 1f,
                1f, 1f,
            ),
        )
        private val cameraTexBuffer = floatBuffer(
            floatArrayOf(
                0f, 0f,
                1f, 0f,
                0f, 1f,
                1f, 1f,
            ),
        )
        private val overlayTexBuffer = floatBuffer(
            floatArrayOf(
                0f, 1f,
                1f, 1f,
                0f, 0f,
                1f, 0f,
            ),
        )
        private val transform = FloatArray(16)
        private val rotationMatrix = FloatArray(16)
        private var overlayTexture = 0

        init {
            Matrix.setIdentityM(rotationMatrix, 0)
            Matrix.translateM(rotationMatrix, 0, 0.5f, 0.5f, 0f)
            Matrix.rotateM(rotationMatrix, 0, rotation.toFloat(), 0f, 0f, 1f)
            Matrix.translateM(rotationMatrix, 0, -0.5f, -0.5f, 0f)
        }

        fun setup(watermark: Bitmap) {
            GLES20.glViewport(0, 0, width, height)
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            overlayTexture = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTexture)
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, watermark, 0)
        }

        fun render(
            surfaceTexture: android.graphics.SurfaceTexture,
            decoderTextureId: Int,
        ) {
            GLES20.glViewport(0, 0, width, height)
            GLES20.glDisable(GLES20.GL_BLEND)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            GLES20.glUseProgram(cameraProgram)
            val cameraPosition = GLES20.glGetAttribLocation(cameraProgram, "aPosition")
            val cameraTexCoord = GLES20.glGetAttribLocation(cameraProgram, "aTexCoord")
            val cameraMatrix = GLES20.glGetUniformLocation(cameraProgram, "uTexMatrix")
            val cameraRotation = GLES20.glGetUniformLocation(cameraProgram, "uRotation")
            val cameraSampler = GLES20.glGetUniformLocation(cameraProgram, "sTexture")
            surfaceTexture.getTransformMatrix(transform)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, decoderTextureId)
            GLES20.glUniform1i(cameraSampler, 0)
            GLES20.glUniformMatrix4fv(cameraMatrix, 1, false, transform, 0)
            GLES20.glUniformMatrix4fv(cameraRotation, 1, false, rotationMatrix, 0)
            bindBuffer(cameraPosition, positionBuffer, 2)
            bindBuffer(cameraTexCoord, cameraTexBuffer, 2)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
            GLES20.glUseProgram(overlayProgram)
            val overlayPosition = GLES20.glGetAttribLocation(overlayProgram, "aPosition")
            val overlayTexCoord = GLES20.glGetAttribLocation(overlayProgram, "aTexCoord")
            val overlaySampler = GLES20.glGetUniformLocation(overlayProgram, "sTexture")
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTexture)
            GLES20.glUniform1i(overlaySampler, 0)
            bindBuffer(overlayPosition, positionBuffer, 2)
            bindBuffer(overlayTexCoord, overlayTexBuffer, 2)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(cameraPosition)
            GLES20.glDisableVertexAttribArray(cameraTexCoord)
            GLES20.glDisableVertexAttribArray(overlayPosition)
            GLES20.glDisableVertexAttribArray(overlayTexCoord)
        }

        private fun bindBuffer(location: Int, buffer: FloatBuffer, stride: Int) {
            if (location < 0) return
            buffer.position(0)
            GLES20.glEnableVertexAttribArray(location)
            GLES20.glVertexAttribPointer(location, stride, GLES20.GL_FLOAT, false, 0, buffer)
        }

        fun release() {
            if (overlayTexture != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(overlayTexture), 0)
            }
            GLES20.glDeleteProgram(cameraProgram)
            GLES20.glDeleteProgram(overlayProgram)
        }

        private fun createProgram(vertex: String, fragment: String): Int {
            val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertex)
            val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragment)
            return GLES20.glCreateProgram().also { program ->
                GLES20.glAttachShader(program, vertexShader)
                GLES20.glAttachShader(program, fragmentShader)
                GLES20.glLinkProgram(program)
                val status = IntArray(1)
                GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
                check(status[0] == GLES20.GL_TRUE) {
                    "GL 程序链接失败：${GLES20.glGetProgramInfoLog(program)}"
                }
                GLES20.glDeleteShader(vertexShader)
                GLES20.glDeleteShader(fragmentShader)
            }
        }

        private fun compileShader(type: Int, source: String): Int {
            return GLES20.glCreateShader(type).also { shader ->
                GLES20.glShaderSource(shader, source)
                GLES20.glCompileShader(shader)
                val status = IntArray(1)
                GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
                check(status[0] == GLES20.GL_TRUE) {
                    "GL 着色器编译失败：${GLES20.glGetShaderInfoLog(shader)}"
                }
            }
        }

        private fun floatBuffer(values: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .apply {
                    put(values)
                    position(0)
                }

        companion object {
            private const val CAMERA_VERTEX_SHADER = """
                uniform mat4 uTexMatrix;
                uniform mat4 uRotation;
                attribute vec4 aPosition;
                attribute vec4 aTexCoord;
                varying vec2 vTexCoord;
                void main() {
                    gl_Position = aPosition;
                    vTexCoord = (uTexMatrix * uRotation * aTexCoord).xy;
                }
            """
            private const val CAMERA_FRAGMENT_SHADER = """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                uniform samplerExternalOES sTexture;
                varying vec2 vTexCoord;
                void main() {
                    gl_FragColor = texture2D(sTexture, vTexCoord);
                }
            """
            private const val OVERLAY_VERTEX_SHADER = """
                attribute vec4 aPosition;
                attribute vec4 aTexCoord;
                varying vec2 vTexCoord;
                void main() {
                    gl_Position = aPosition;
                    vTexCoord = aTexCoord.xy;
                }
            """
            private const val OVERLAY_FRAGMENT_SHADER = """
                precision mediump float;
                uniform sampler2D sTexture;
                varying vec2 vTexCoord;
                void main() {
                    gl_FragColor = texture2D(sTexture, vTexCoord);
                }
            """
        }
    }
}
