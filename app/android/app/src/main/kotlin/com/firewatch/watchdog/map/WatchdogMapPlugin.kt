package com.firewatch.watchdog.map

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.Keep
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 现场实时卫星地图原生视图插件。
 *
 * 使用系统 WebView 承载高德 JS API 2.0 页面，隔离在独立的 PlatformView 视图工厂下：
 * - 禁用文件与 Content URI 访问，阻断任何偏离 baseUrl origin 的顶层跳转；
 * - 提供 `WatchdogMapBridge` JS 桥接与 `watchdog/amap_view_<id>` MethodChannel 通信；
 * - 页面销毁时清理 WebView 及 JS 接口，防止 WebGL 上下文残留。
 */
object WatchdogMapPlugin {
    const val VIEW_TYPE = "watchdog/amap_view"
}

class WatchdogMapViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        return WatchdogMapPlatformView(context, messenger, viewId, params)
    }
}

class WatchdogMapPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<*, *>?,
) : PlatformView {

    private val channel = MethodChannel(messenger, "watchdog/amap_view_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var allowedBaseOrigin: String? = null
    private var disposed = false

    @SuppressLint("SetJavaScriptEnabled")
    private val webView: WebView = WebView(context).apply {
        val bg = (params?.get("backgroundColor") as? Number)?.toInt() ?: Color.BLACK
        setBackgroundColor(bg)
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = true
        }
        overScrollMode = View.OVER_SCROLL_NEVER
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        addJavascriptInterface(JsBridge(), "WatchdogMapBridge")
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean {
                val url = request?.url ?: return true
                if (!request.isForMainFrame) return false
                val target = url.toString()
                if (target == "about:blank") return false
                val allowed = allowedBaseOrigin
                return allowed == null || originOf(url) != allowed
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                if (disposed || request?.isForMainFrame != true) return
                val message = error?.description?.toString()?.takeIf { it.isNotBlank() }
                    ?: "地图视图加载失败"
                dispatchBridgeMessage("""{"type":"loadError","message":${jsonQuote(message)}}""")
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("disposed", "地图视图已销毁", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "loadHtml" -> {
                    val html = call.argument<String>("html")
                    val baseUrl = call.argument<String>("baseUrl")
                    if (html.isNullOrBlank()) {
                        result.error("invalid_html", "缺少地图 HTML 内容", null)
                    } else {
                        allowedBaseOrigin = baseUrl
                            ?.takeIf { it.isNotBlank() }
                            ?.let { runCatching { originOf(Uri.parse(it)) }.getOrNull() }
                        webView.loadDataWithBaseURL(
                            baseUrl?.takeIf { it.isNotBlank() },
                            html,
                            "text/html",
                            "UTF-8",
                            null,
                        )
                        result.success(null)
                    }
                }
                "evalJs" -> {
                    val script = call.argument<String>("script")
                    if (script.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        webView.evaluateJavascript(script, null)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = webView

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
        runCatching { webView.removeJavascriptInterface("WatchdogMapBridge") }
        runCatching { webView.stopLoading() }
        runCatching { webView.loadUrl("about:blank") }
        runCatching { webView.removeAllViews() }
        runCatching { webView.destroy() }
    }

    private fun dispatchBridgeMessage(payload: String) {
        mainHandler.post {
            if (disposed) return@post
            runCatching {
                channel.invokeMethod("onBridgeMessage", payload)
            }
        }
    }

    @Keep
    private inner class JsBridge {
        @Keep
        @JavascriptInterface
        fun postMessage(payload: String?) {
            if (disposed || payload.isNullOrBlank()) return
            dispatchBridgeMessage(payload)
        }
    }

    private fun originOf(uri: Uri): String? {
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        val port = uri.port
        return if (port == -1) "$scheme://$host" else "$scheme://$host:$port"
    }

    private fun jsonQuote(value: String): String {
        val sb = StringBuilder(value.length + 2)
        sb.append('"')
        for (ch in value) {
            when (ch) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> sb.append(ch)
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
