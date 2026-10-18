package com.firewatch.watchdog.camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.view.Surface
import android.os.Handler
import android.os.HandlerThread
import android.view.View
import android.util.Log
import android.os.Looper
import androidx.camera.core.CameraEffect
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.SurfaceOutput
import com.google.common.util.concurrent.ListenableFuture
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
    private var effectLifetime: EffectLifetime? = null
    private var preview: Preview? = null
    private var displayManager: DisplayManager? = null
    private var recording: Recording? = null
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    @Volatile
    private var sessionGeneration = 0
    private var torchOn = false
    @Volatile
    private var disposed = false
    private var started = false

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
        if (started || disposed) return
        started = true
        bindRetries = 0
        previewView.addOnLayoutChangeListener(layoutListener)
        startDisplayListener()
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                provider = future.get()
                scheduleRotationUpdate(immediateIfReady = true)
            } catch (error: Exception) {
                callbacks.onError("provider_failed", error.message ?: "相机初始化失败")
            }
        }, mainExecutor)
    }

    private fun bind() {
        val cameraProvider = provider ?: return
        if (disposed) return
        val oldUseCases = listOfNotNull(this.preview, imageCapture, videoCapture)
        retireEffect()
        if (oldUseCases.isNotEmpty()) cameraProvider.unbind(*oldUseCases.toTypedArray())
        val rotation = currentRotation()

        // 预览、照片、录像统一 16:9：三者共用同一个 OverlayEffect，
        // 若宽高比不同（例如照片 4:3、录像 16:9），水印在成片里会被裁掉边缘。
        val preview = Preview.Builder()
            .setTargetRotation(rotation)
            .setTargetAspectRatio(androidx.camera.core.AspectRatio.RATIO_16_9)
            .build().also {
            it.surfaceProvider = previewView.surfaceProvider
        }
        val capture = ImageCapture.Builder()
            .setTargetRotation(rotation)
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .setTargetAspectRatio(androidx.camera.core.AspectRatio.RATIO_16_9)
            .build()
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.fromOrderedList(
                    listOf(Quality.FHD, Quality.HD),
                    androidx.camera.video.FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                ),
            )
            .build()
        val video = VideoCapture.Builder(recorder)
            .setTargetRotation(rotation)
            .build()

        // 每次进相机页都是一次新会话：复位释放标记并索取代际号，
        // 防止上一会话的后台释放任务误伤本次会话的水印缓存。
        sessionGeneration = WatermarkOverlay.resetForNewSession()
        // queueDepth = 0：帧到即画、立即合成，不排队。水印绘制是纯 Canvas 同步操作，
        // 排队只会增加一帧延迟，没有收益。
        // Handler 是 CameraX 的 GL 执行线程，而非 UI 通知线程。每个 effect 独占
        // 一条线程，避免旧 effect 的 close 清除新 effect 的 current EGLContext。
        val glThread = HandlerThread("watchdog-camera-gl").apply { start() }
        val lifetime = EffectLifetime(glThread)
        effectLifetime = lifetime
        val effect = OverlayEffect(
            CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE or CameraEffect.IMAGE_CAPTURE,
            0,
            Handler(glThread.looper),
        ) { error ->
            mainHandler.post {
                if (!disposed) callbacks.onError("overlay_failed", error.message ?: "水印渲染失败")
            }
        }
        // 回调只负责在 Canvas 上绘制；返回 true 后由 OverlayEffect 自行把 overlay 纹理
        // 与相机帧混合输出。这里绝不能再调用 drawFrameAsync：
        // 那会把同一帧二次消费，触发 "Frame is already empty" 崩溃。
        effect.setOnDrawListener { frame ->
            val canvas = frame.overlayCanvas
            if (canvas == null || disposed) {
                false
            } else {
                WatermarkOverlay.draw(canvas, frame, watermark)
                true
            }
        }

        val delegate = checkNotNull(effect.surfaceProcessor)
        // 跟踪 effect 真正接收的输入 surface。三路 UseCase 可能被 StreamSharing
        // 包成内部 UseCase，直接读 Preview/VideoCapture 的 SessionConfig 会漏掉它。
        val processor = object : SurfaceProcessor {
            override fun onInputSurface(request: SurfaceRequest) {
                if (lifetime.closing) {
                    request.willNotProvideSurface()
                    return
                }
                trackInputSurface(lifetime, request)
                delegate.onInputSurface(request)
            }

            override fun onOutputSurface(output: SurfaceOutput) {
                if (lifetime.closing) output.close() else delegate.onOutputSurface(output)
            }
        }
        val trackedEffect = object : CameraEffect(
            effect.targets, effect.transformation, effect.outputOption,
            effect.executor, processor, effect.errorListener,
        ) {}
        val group = UseCaseGroup.Builder()
            .addUseCase(preview)
            .addUseCase(capture)
            .addUseCase(video)
            .addEffect(trackedEffect)
            .build()

        this.preview = preview
        imageCapture = capture
        videoCapture = video
        overlayEffect = effect
        lastAppliedRotation = rotation
        try {
            camera = cameraProvider.bindToLifecycle(lifecycleOwner, currentSelector(), group)
        } catch (error: Exception) {
            retireEffect()
            throw error
        }
        if (torchOn) camera?.cameraControl?.enableTorch(true)
    }

    private fun currentRotation(): Int = previewView.display?.rotation ?: Surface.ROTATION_0

    private var bindRetries = 0
    private val maxBindRetries = 60 // 60 * 50ms = 3000ms 自愈轮询上限

    private fun isReadyForBind(): Boolean {
        if (disposed || provider == null || previewView.display == null) return false
        if (previewView.width <= 0 || previewView.height <= 0) return false
        if (context.resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE ||
            previewView.width <= previewView.height) {
            return false
        }
        return true
    }

    // 初始 attach/layout 与显示旋转只共用一个可取消任务；布局稳定后才首次绑定。
    // 不再在 bind 完成后立即改 targetRotation，也不再用 300/900ms 定时补偿。
    private val updateRotation: Runnable = Runnable {
        if (disposed) return@Runnable
        if (preview == null) {
            if (!isReadyForBind()) {
                // 条件尚未就绪，自愈重新排队轮询，直到就绪或超时
                if (bindRetries < maxBindRetries) {
                    bindRetries++
                    mainHandler.removeCallbacks(updateRotation)
                    mainHandler.postDelayed(updateRotation, 50)
                } else {
                    callbacks.onError("bind_timeout", "相机就绪超时：等待布局/横屏就绪超过 3 秒")
                }
                return@Runnable
            }
            try {
                bind()
            } catch (error: Exception) {
                callbacks.onError("bind_failed", error.message ?: "相机初始化失败")
            }
        } else {
            if (previewView.display != null && currentRotation() != lastAppliedRotation) {
                try {
                    applyTargetRotation()
                } catch (error: Exception) {
                    callbacks.onError("rotation_failed", error.message ?: "旋转更新失败")
                }
            }
        }
    }

    private fun scheduleRotationUpdate(immediateIfReady: Boolean = false) {
        if (disposed) return
        mainHandler.removeCallbacks(updateRotation)
        if (preview == null) {
            if (isReadyForBind()) {
                if (immediateIfReady) {
                    updateRotation.run()
                } else {
                    mainHandler.post(updateRotation)
                }
            } else {
                mainHandler.postDelayed(updateRotation, 50)
            }
        } else {
            if (currentRotation() != lastAppliedRotation) {
                mainHandler.post(updateRotation)
            }
        }
    }

    private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        if (preview == null || currentRotation() != lastAppliedRotation) scheduleRotationUpdate(immediateIfReady = true)
    }

    /** 仅真实显示方向变化时更新；普通布局变化不碰已绑定的 UseCase。 */
    private fun applyTargetRotation() {
        val rotation = currentRotation()
        if (rotation == lastAppliedRotation) return
        lastAppliedRotation = rotation
        preview?.targetRotation = rotation
        imageCapture?.targetRotation = rotation
        videoCapture?.targetRotation = rotation
    }

    private fun startDisplayListener() {
        val manager = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return
        if (displayManager === manager) return
        stopDisplayListener()
        displayManager = manager
        manager.registerDisplayListener(displayListener, mainHandler)
    }

    private fun stopDisplayListener() {
        val manager = displayManager ?: return
        runCatching { manager.unregisterDisplayListener(displayListener) }
        displayManager = null
    }

    private var lastAppliedRotation = -1

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == previewView.display?.displayId &&
                currentRotation() != lastAppliedRotation) scheduleRotationUpdate()
        }
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

        recording = pending.start(mainExecutor) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    callbacks.onRecordingEvent(mapOf("type" to "started"))
                    mainHandler.postDelayed(stopAtLimit, maxDurationMs)
                }
                is VideoRecordEvent.Finalize -> {
                    mainHandler.removeCallbacks(stopAtLimit)
                    val durationMs = event.recordingStats.recordedDurationNanos / 1_000_000
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

    /**
     * 释放会话。必须在主线程调用，但自身不允许做重活。
     *
     * 两条约束：
     * 1. 只解绑本会话自己的 UseCase。`ProcessCameraProvider` 是进程级单例，
     *    用 unbindAll() 会误伤紧接着重进页面时新会话刚绑好的用例。
     * 2. effect 的 close 与绘制在所属 GL 线程串行执行，不能阻塞主线程。
     */
    fun release() {
        if (disposed) return
        disposed = true
        mainHandler.removeCallbacksAndMessages(null)
        bindRetries = 0
        stopDisplayListener()
        previewView.removeOnLayoutChangeListener(layoutListener)
        val cameraProvider = provider
        val useCases = listOfNotNull(preview, imageCapture, videoCapture)
        preview = null
        imageCapture = null
        videoCapture = null
        camera = null
        provider = null

        recording?.stop()
        recording = null

        retireEffect()
        if (cameraProvider != null && useCases.isNotEmpty()) {
            runCatching { cameraProvider.unbind(*useCases.toTypedArray()) }
        }
    }

    private class EffectLifetime(val thread: HandlerThread) {
        // 以下状态只在本 effect 的 GL 线程读写。
        val terminations = mutableListOf<ListenableFuture<Void>>()
        var closing = false
        var barrierAvailable = true
    }

    @SuppressLint("RestrictedApi")
    private fun trackInputSurface(lifetime: EffectLifetime, request: SurfaceRequest) {
        // 依赖 CameraX 1.6.2 的 SurfaceRequest.getDeferrableSurface() 与
        // DeferrableSurface.getTerminationFuture()；升级 CameraX 时必须回归此屏障。
        try {
            lifetime.terminations.add(request.deferrableSurface.terminationFuture)
        } catch (error: Exception) {
            lifetime.barrierAvailable = false
            Log.w("WatchdogCamera", "Surface termination barrier unavailable; delaying GL quit", error)
        } catch (error: LinkageError) {
            lifetime.barrierAvailable = false
            Log.w("WatchdogCamera", "CameraX termination API changed; delaying GL quit", error)
        }
    }

    /** close 在 GL 线程执行；等相机交回所有输入 surface，再退出线程。 */
    private fun retireEffect() {
        val effect = overlayEffect
        val lifetime = effectLifetime ?: return
        val generation = sessionGeneration
        overlayEffect = null
        effectLifetime = null
        val handler = Handler(lifetime.thread.looper)
        handler.post {
            lifetime.closing = true
            try {
                effect?.close()
            } finally {
                WatermarkOverlay.release(generation)
                if (!lifetime.barrierAvailable) {
                    handler.postDelayed({ lifetime.thread.quitSafely() }, 1_000)
                } else if (lifetime.terminations.isEmpty()) {
                    lifetime.thread.quitSafely()
                } else {
                    var remaining = lifetime.terminations.size
                    val executor = java.util.concurrent.Executor { handler.post(it) }
                    lifetime.terminations.forEach { future ->
                        future.addListener({
                            remaining -= 1
                            if (remaining == 0) {
                                // 先消费同一次终止触发的 texture / surface 回收回调。
                                handler.post { lifetime.thread.quitSafely() }
                            }
                        }, executor)
                    }
                }
            }
        }
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
