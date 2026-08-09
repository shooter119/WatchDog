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
import java.security.MessageDigest
import java.util.Locale

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
                    val apk = downloadedUpdateFile(call.argument<String>("filename"))
                    result.success(apk?.let { it.isFile && it.length() > 0L } ?: false)
                }
                "verifyDownloadedUpdate" -> {
                    val apk = downloadedUpdateFile(call.argument<String>("filename"))
                    val expectedSha = call.argument<String>("sha256")
                    val expectedVersionCode = call.argument<Number>("versionCode")?.toLong()
                    result.success(
                        apk != null && expectedSha != null && expectedVersionCode != null &&
                            verifyDownloadedUpdate(apk, expectedSha, expectedVersionCode),
                    )
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
                            val apk = downloadedUpdateFile(call.argument<String>("filename"))
                            if (apk == null || !apk.isFile || apk.length() == 0L) {
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

    private fun downloadedUpdateFile(filename: String?): File? {
        val actualName = filename ?: "watchdog-update.apk"
        // 文件名由 Dart 端生成，但原生端仍拒绝路径穿越，避免 FileProvider 暴露任意文件。
        if (actualName.isBlank() || actualName != File(actualName).name ||
            !actualName.endsWith(".apk", ignoreCase = true)
        ) {
            return null
        }
        return File(filesDir, "ota_update/$actualName")
    }

    private fun verifyDownloadedUpdate(apk: File, expectedSha: String, expectedVersionCode: Long): Boolean {
        return try {
            if (!apk.isFile || apk.length() == 0L) return false
            val actualSha = sha256(apk)
            if (!actualSha.equals(expectedSha.trim(), ignoreCase = true)) return false

            val packageInfo = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageArchiveInfo(apk.path, android.content.pm.PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageArchiveInfo(apk.path, 0)
            } ?: return false
            if (packageInfo.packageName != packageName) return false
            val actualVersionCode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode.toLong()
            }
            actualVersionCode == expectedVersionCode
        } catch (_: Exception) {
            false
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            var count = input.read(buffer)
            while (count > 0) {
                digest.update(buffer, 0, count)
                count = input.read(buffer)
            }
        }
        return digest.digest().joinToString("") { byte ->
            String.format(Locale.US, "%02x", byte.toInt() and 0xff)
        }
    }
}
