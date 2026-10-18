package com.firewatch.watchdog.camera

import android.content.ClipData
import android.content.Context
import android.content.ContextWrapper
import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.util.concurrent.Executors

/**
 * Flutter 与水印相机之间的桥。
 *
 * - PlatformView `watchdog/camera_view`：承载 CameraX 的预览画面
 * - MethodChannel `watchdog/camera`：拍照、录像、切换镜头、手电筒、更新水印
 * - EventChannel `watchdog/camera_events`：录制开始/结束/到达时长上限/错误
 */
class WatchdogCameraPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val locationChannel = MethodChannel(messenger, LOCATION_CHANNEL)
    private val mediaChannel = MethodChannel(messenger, MEDIA_CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var eventSink: EventChannel.EventSink? = null
    private var activeView: CameraPreviewView? = null

    fun register() {
        // 队徽资源在原生侧解码，注入 Application 上下文即可，不持有 Activity
        WatermarkOverlay.install(context)
        eventChannel.setStreamHandler(this)
        locationChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(LocationHelper.hasPermission(context))
                "getLocation" -> {
                    if (!LocationHelper.hasPermission(context)) {
                        result.success(null)
                    } else {
                        val timeoutMs = ((call.arguments as? Map<*, *>)?.get("timeoutMs") as? Number)
                            ?.toLong() ?: 8_000L
                        LocationHelper.current(context, timeoutMs) { fix ->
                            result.success(fix?.toMap())
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        methodChannel.setMethodCallHandler { call, result ->
            val view = activeView
            when (call.method) {
                "takePhoto" -> {
                    if (view == null) {
                        result.error("not_ready", "相机预览尚未创建", null)
                    } else {
                        view.session.takePhoto { outcome ->
                            outcome.fold(
                                onSuccess = { path -> result.success(path) },
                                onFailure = { error ->
                                    result.error("photo_failed", error.message, null)
                                },
                            )
                        }
                    }
                }
                "startRecording" -> {
                    view?.session?.startRecording() ?: result.error("not_ready", "相机预览尚未创建", null)
                    if (view != null) result.success(null)
                }
                "stopRecording" -> {
                    view?.session?.stopRecording()
                    result.success(null)
                }
                "switchCamera" -> {
                    view?.session?.switchLens()
                    result.success(null)
                }
                "setTorch" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    view?.session?.setTorch(on)
                    result.success(null)
                }
                "updateWatermark" -> {
                    val map = call.arguments as? Map<*, *>
                    if (view != null && map != null) {
                        view.session.setWatermark(WatermarkModel.fromMap(map))
                    }
                    result.success(null)
                }
                "setMaxDuration" -> {
                    val ms = (call.argument<Number>("maxDurationMs"))?.toLong()
                    if (view != null && ms != null) view.session.maxDurationMs = ms
                    result.success(null)
                }
                "isRecording" -> result.success(view?.session?.isRecording ?: false)
                "requestPermissions" -> requestRuntimePermissions(result)
                "permissionState" -> result.success(currentPermissionState())
                "hasCameraPermission" -> result.success(
                    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                        PackageManager.PERMISSION_GRANTED,
                )
                "extractAudioWav" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "缺少视频路径", null)
                    } else {
                        worker.execute {
                            val source = File(path)
                            val target = File(source.parentFile, "${'$'}{source.nameWithoutExtension}.wav")
                            val wav = MediaDerivatives.extractWav(source, target)
                            mainHandler.post { result.success(wav?.absolutePath) }
                        }
                    }
                }
                "extractFrames" -> {
                    val path = call.argument<String>("path")
                    val count = call.argument<Int>("count") ?: 3
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "缺少视频路径", null)
                    } else {
                        worker.execute {
                            val source = File(path)
                            val dir = File(source.parentFile, "frames_${'$'}{source.nameWithoutExtension}")
                            val frames = MediaDerivatives.extractFrames(source, dir, count)
                            mainHandler.post { result.success(frames.map { it.absolutePath }) }
                        }
                    }
                }
                "openWithSystem" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "缺少文件路径", null)
                    } else {
                        openWithSystem(path, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun disposePlugin() {
        eventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
        locationChannel.setMethodCallHandler(null)
        mediaChannel.setMethodCallHandler(null)
        worker.shutdownNow()
        activeView = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    /**
     * 运行时权限：相机是必需项，麦克风与定位是可选项（拒绝也允许拍摄静音视频/无水印位置）。
     * 之前只用系统相机拍照，清单里的 CAMERA 从未真正被申请过。
     */
    private fun requestRuntimePermissions(result: MethodChannel.Result) {
        val activity = context.findActivity()
        if (activity == null) {
            result.error("no_activity", "无法获取 Activity", null)
            return
        }
        val missing = PERMISSIONS.filter {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(currentPermissionState())
            return
        }
        pendingPermissionResult = result
        // Android 12+ 要求 ACCESS_FINE_LOCATION 与 ACCESS_COARSE_LOCATION 同批申请，
        // 只请求 FINE 会被系统静默忽略，导致地址/天气永远取不到。
        ActivityCompat.requestPermissions(activity, missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    private fun currentPermissionState(): Map<String, Boolean> = mapOf(
        "camera" to granted(Manifest.permission.CAMERA),
        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
        "location" to (granted(Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(Manifest.permission.ACCESS_COARSE_LOCATION)),
        "preciseLocation" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
    )

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** 由 MainActivity 转发；返回 true 表示本次结果由相机插件消费。 */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        pendingPermissionResult?.success(currentPermissionState())
        pendingPermissionResult = null
        return true
    }

    /** 用系统默认应用打开媒体文件（播放器/图片查看器），文件通过 FileProvider 临时授权。 */
    private fun openWithSystem(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.isFile) {
            result.error("not_found", "文件不存在", null)
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${'$'}{context.packageName}.ota_update_provider",
                file,
            )
            val mime = when (file.extension.lowercase()) {
                "mp4" -> "video/mp4"
                "jpg", "jpeg" -> "image/jpeg"
                "wav" -> "audio/wav"
                else -> "*/*"
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                clipData = ClipData.newRawUri("watchdog-media", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "无法打开文件", null)
        }
    }

    private fun emit(event: Map<String, Any?>) {
        eventSink?.success(event)
    }

    inner class PreviewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val params = args as? Map<*, *>
            val view = CameraPreviewView(context, params, ::emit)
            activeView = view
            return view
        }
    }

    companion object {
        const val METHOD_CHANNEL = "watchdog/camera"
        const val EVENT_CHANNEL = "watchdog/camera_events"
        const val VIEW_TYPE = "watchdog/camera_view"
        const val LOCATION_CHANNEL = "watchdog/location"
        const val MEDIA_CHANNEL = "watchdog/media"
        private const val PERMISSION_REQUEST_CODE = 4711
        private val PERMISSIONS = arrayOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
    }
}

/** 预览视图：内部持有 CameraSession，界面销毁时一并释放相机资源。 */
class CameraPreviewView(
    context: Context,
    params: Map<*, *>?,
    private val emit: (Map<String, Any?>) -> Unit,
) : PlatformView {

    private val previewView = PreviewView(context).apply {
        // 用 FIT_CENTER 而不是 FILL_CENTER：取景画面与录制文件必须一致，
        // 否则预览里看不到的边角会出现在成片里，水印位置会对不上。
        scaleType = PreviewView.ScaleType.FIT_CENTER
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }

    val session: CameraSession

    init {
        val owner = context.findLifecycleOwner()
            ?: throw IllegalStateException("相机预览需要 LifecycleOwner 上下文")
        session = CameraSession(
            context = context,
            lifecycleOwner = owner,
            previewView = previewView,
            callbacks = object : CameraSession.Callbacks {
                override fun onRecordingEvent(event: Map<String, Any?>) = emit(event)
                override fun onError(code: String, message: String) {
                    emit(mapOf("type" to "error", "code" to code, "message" to message))
                }
            },
        )
        val watermark = WatermarkModel.fromMap(params?.get("watermark") as? Map<*, *>)
        session.setWatermark(watermark)
        (params?.get("maxDurationMs") as? Number)?.let { session.maxDurationMs = it.toLong() }
        session.start()
    }

    override fun getView(): View = previewView

    override fun dispose() {
        session.release()
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

private tailrec fun Context.findLifecycleOwner(): LifecycleOwner? = when (this) {
    is LifecycleOwner -> this
    is ContextWrapper -> baseContext.findLifecycleOwner()
    else -> null
}
