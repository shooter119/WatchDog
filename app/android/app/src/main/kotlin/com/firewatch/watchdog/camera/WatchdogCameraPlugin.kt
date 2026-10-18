package com.firewatch.watchdog.camera

import android.content.Context
import android.content.ContextWrapper
import android.view.View
import androidx.camera.view.PreviewView
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

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
    private var eventSink: EventChannel.EventSink? = null
    private var activeView: CameraPreviewView? = null

    fun register() {
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
                else -> result.notImplemented()
            }
        }
    }

    fun disposePlugin() {
        eventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
        locationChannel.setMethodCallHandler(null)
        activeView = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
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
    }
}

/** 预览视图：内部持有 CameraSession，界面销毁时一并释放相机资源。 */
class CameraPreviewView(
    context: Context,
    params: Map<*, *>?,
    private val emit: (Map<String, Any?>) -> Unit,
) : PlatformView {

    private val previewView = PreviewView(context).apply {
        scaleType = PreviewView.ScaleType.FILL_CENTER
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

private tailrec fun Context.findLifecycleOwner(): LifecycleOwner? = when (this) {
    is LifecycleOwner -> this
    is ContextWrapper -> baseContext.findLifecycleOwner()
    else -> null
}
