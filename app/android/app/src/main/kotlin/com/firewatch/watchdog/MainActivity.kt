package com.firewatch.watchdog

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "watchdog/screen"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "keepScreenOn" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    runOnUiThread {
                        if (enable) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                "androidId" -> {
                    // 零权限设备标识（SSAID）：同一设备+同一签名下卸载重装不变
                    val id = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
                    result.success(id)
                }
                "openAppSettings" -> {
                    // 麦克风权限被拒后的恢复路径：打开本应用的系统设置页
                    runOnUiThread {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open_settings_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
