package com.firewatch.watchdog

import android.content.ClipData
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "watchdog/screen"
    private val alarmChannelName = "watchdog/alarm"

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
                "canRequestPackageInstalls" -> {
                    // Android 8+ 安装 APK 需"安装未知来源应用"授权（API 26 以下无此概念，视为已授权）
                    val can = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(can)
                }
                "openUnknownAppSourcesSettings" -> {
                    // 引导用户授权"安装未知来源应用"（OTA 安装前置条件）
                    runOnUiThread {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
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
                "hasDownloadedUpdate" -> {
                    val apk = downloadedUpdateFile()
                    result.success(apk.isFile && apk.length() > 0L)
                }
                "installDownloadedUpdate" -> {
                    // 用户取消安装或系统安装页被打断后，直接复用已校验的 APK，
                    // 不再重新下载。FileProvider URI 仅授予安装器临时只读权限。
                    runOnUiThread {
                        try {
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                                !packageManager.canRequestPackageInstalls()
                            ) {
                                result.error("install_permission_denied", "尚未允许安装未知来源应用", null)
                                return@runOnUiThread
                            }
                            val apk = downloadedUpdateFile()
                            if (!apk.isFile || apk.length() == 0L) {
                                result.error("apk_not_found", "已下载的安装包不存在", null)
                                return@runOnUiThread
                            }
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.ota_update_provider",
                                apk,
                            )
                            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                                data = uri
                                clipData = ClipData.newRawUri("watchdog-update", uri)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open_installer_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, alarmChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                // 报警时把 ALARM 流音量拉到最大（火场高分贝环境确保听到）
                "maxAlarmVolume" -> {
                    runOnUiThread {
                        val am = getSystemService(AUDIO_SERVICE) as AudioManager
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                        am.setStreamVolume(AudioManager.STREAM_ALARM, max, 0)
                    }
                    result.success(null)
                }
                "isNotificationPolicyAccessGranted" -> {
                    val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
                    result.success(nm.isNotificationPolicyAccessGranted)
                }
                // 勿扰权限被拒后的恢复路径：跳系统勿扰设置页
                "openNotificationPolicySettings" -> {
                    runOnUiThread {
                        try {
                            val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open_policy_settings_failed", e.message, null)
                        }
                    }
                }
                // Android 14+ 全屏通知被系统默认关闭，跳本应用通知设置页让用户手动开启
                "openNotificationSettings" -> {
                    runOnUiThread {
                        try {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open_notification_settings_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun downloadedUpdateFile(): File =
        File(filesDir, "ota_update/watchdog-update.apk")
}
