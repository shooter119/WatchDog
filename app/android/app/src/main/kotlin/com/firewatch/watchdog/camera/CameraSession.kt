package com.firewatch.watchdog.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraEffect
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.effects.OverlayEffect
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 相机会话：预览 + 照片 + 录像，三者共用同一个 OverlayEffect，
 * 因此水印在预览里所见即所得，并直接烧进照片与录像像素，不依赖二次转码。
 */
class CameraSession(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val previewView: PreviewView,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        fun onRecordingEvent(event: Map<String, Any?>)
        fun onError(code: String, message: String)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = ContextCompat.getMainExecutor(context)

    private var provider: ProcessCameraProvider? = null
    private var camera: androidx.camera.core.Camera? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var overlayEffect: OverlayEffect? = null
    private var recording: Recording? = null
    private var recordingStartedAt = 0L
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var torchOn = false
    private var disposed = false

    /** 当前生效的水印；录制开始时冻结时间戳并保持不变。 */
    @Volatile
    private var watermark = WatermarkModel()

    var maxDurationMs: Long = 60_000L
        set(value) {
            field = value.coerceIn(5_000L, 300_000L)
        }

    private val stopAtLimit = Runnable { stopRecording(autoStopped = true) }

    val isRecording: Boolean get() = recording != null

    fun setWatermark(model: WatermarkModel) {
        // 录制中不允许改水印，保证成片水印与开始时一致
        if (recording == null) watermark = model
    }

    fun start() {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                provider = future.get()
                bind()
            } catch (error: Exception) {
                callbacks.onError("provider_failed", error.message ?: "相机初始化失败")
            }
        }, mainExecutor)
    }

    private fun bind() {
        val cameraProvider = provider ?: return
        cameraProvider.unbindAll()

        val preview = Preview.Builder().build().also {
            it.surfaceProvider = previewView.surfaceProvider
        }
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.fromOrderedList(
                    listOf(Quality.FHD, Quality.HD, Quality.SD),
                    androidx.camera.video.FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                ),
            )
            .build()
        val video = VideoCapture.withOutput(recorder)

        val effect = OverlayEffect(
            CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE or CameraEffect.IMAGE_CAPTURE,
            2,
            mainHandler,
        ) { error -> callbacks.onError("overlay_failed", error.message ?: "水印渲染失败") }
        effect.setOnDrawListener { frame ->
            val canvas = frame.overlayCanvas
            if (canvas == null || disposed) {
                false
            } else {
                WatermarkOverlay.draw(canvas, watermark)
                effect.drawFrameAsync(frame.timestampNanos)
                true
            }
        }

        val group = UseCaseGroup.Builder()
            .addUseCase(preview)
            .addUseCase(capture)
            .addUseCase(video)
            .addEffect(effect)
            .build()

        camera = cameraProvider.bindToLifecycle(lifecycleOwner, currentSelector(), group)
        imageCapture = capture
        videoCapture = video
        overlayEffect = effect
        if (torchOn) camera?.cameraControl?.enableTorch(true)
    }

    private fun currentSelector(): CameraSelector =
        if (lensFacing == CameraSelector.LENS_FACING_FRONT) CameraSelector.DEFAULT_FRONT_CAMERA
        else CameraSelector.DEFAULT_BACK_CAMERA

    fun switchLens() {
        if (recording != null) {
            callbacks.onError("busy", "录制中不能切换摄像头")
            return
        }
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        bind()
    }

    fun setTorch(on: Boolean) {
        torchOn = on
        camera?.cameraControl?.enableTorch(on)
    }

    fun takePhoto(onResult: (Result<String>) -> Unit) {
        val capture = imageCapture ?: run {
            onResult(Result.failure(IllegalStateException("相机尚未就绪")))
            return
        }
        val file = newFile("IMG", "jpg")
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        capture.takePicture(options, mainExecutor, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                onResult(Result.success(file.absolutePath))
            }

            override fun onError(exception: ImageCaptureException) {
                file.delete()
                callbacks.onError("photo_failed", exception.message ?: "拍照失败")
                onResult(Result.failure(exception))
            }
        })
    }

    fun startRecording() {
        if (recording != null) {
            callbacks.onError("busy", "已在录制中")
            return
        }
        val capture = videoCapture ?: run {
            callbacks.onError("not_ready", "相机尚未就绪")
            return
        }
        // 录制期间水印时间戳冻结，成片与预览一致
        watermark = watermark.withFrozenTime()

        val file = newFile("VID", "mp4")
        val options = FileOutputOptions.Builder(file).build()
        val pending = capture.output.prepareRecording(context, options)
        if (hasAudioPermission()) pending.withAudioEnabled()

        recordingStartedAt = System.currentTimeMillis()
        recording = pending.start(mainExecutor) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    callbacks.onRecordingEvent(mapOf("type" to "started"))
                    mainHandler.postDelayed(stopAtLimit, maxDurationMs)
                }
                is VideoRecordEvent.Finalize -> {
                    mainHandler.removeCallbacks(stopAtLimit)
                    val durationMs = System.currentTimeMillis() - recordingStartedAt
                    recording = null
                    if (event.hasError()) {
                        callbacks.onRecordingEvent(
                            mapOf(
                                "type" to "error",
                                "code" to event.error,
                                "message" to (event.cause?.message ?: "录制失败"),
                            ),
                        )
                    } else {
                        callbacks.onRecordingEvent(
                            mapOf(
                                "type" to "stopped",
                                "path" to file.absolutePath,
                                "durationMs" to durationMs,
                                "autoStopped" to (durationMs >= maxDurationMs - 500),
                            ),
                        )
                    }
                }
            }
        }
    }

    fun stopRecording(autoStopped: Boolean = false) {
        val current = recording ?: return
        mainHandler.removeCallbacks(stopAtLimit)
        current.stop()
        if (autoStopped) callbacks.onRecordingEvent(mapOf("type" to "reached_limit"))
    }

    fun release() {
        disposed = true
        mainHandler.removeCallbacksAndMessages(null)
        recording?.stop()
        recording = null
        overlayEffect?.close()
        overlayEffect = null
        provider?.unbindAll()
        provider = null
        imageCapture = null
        videoCapture = null
        camera = null
    }

    private fun hasAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun newFile(prefix: String, extension: String): File {
        val dir = File(mediaRoot(), "capture").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
        return File(dir, "${prefix}_$stamp.$extension")
    }

    /** 与 Flutter 侧约定的媒体根目录：应用私有外部目录，卸载即清理，不参与系统相册。 */
    private fun mediaRoot(): File =
        context.getExternalFilesDir(null) ?: context.filesDir
}
