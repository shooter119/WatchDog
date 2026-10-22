package com.firewatch.watchdog

import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import com.firewatch.watchdog.camera.WatchdogCameraPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "watchdog/screen"
    private val alarmChannelName = "watchdog/alarm"
    private val storageChannelName = "watchdog/storage"
    private val pipChannelName = "watchdog/pip"
    private var cameraPlugin: WatchdogCameraPlugin? = null
    private var pipChannel: MethodChannel? = null
    private var autoEnterPip = false
    private var pipAspect = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 水印相机：原生预览视图 + 拍照/录像/录制事件通道
        val camera = WatchdogCameraPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
        camera.register()
        flutterEngine.platformViewsController.registry.registerViewFactory(
            WatchdogCameraPlugin.VIEW_TYPE,
            camera.PreviewFactory(),
        )
        cameraPlugin = camera

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "availableBytes" -> {
                    result.success(android.os.StatFs(filesDir.path).availableBytes)
                }
                "openAppSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = android.net.Uri.parse("package:$packageName")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_app_settings_failed", null, null)
                    }
                }
                "openStorageSettings" -> {
                    runOnUiThread {
                        try {
                            val intent = Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                })
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("open_storage_settings_failed", e.message, null)
                            }
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
        val pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pip.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    result.success(isPipSupported())
                }
                "setAutoEnter" -> {
                    if (!isPipSupported()) {
                        autoEnterPip = false
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val aspectW = call.argument<Number>("aspectW")?.toInt() ?: 16
                    val aspectH = call.argument<Number>("aspectH")?.toInt() ?: 9
                    autoEnterPip = enabled
                    pipAspect = clampPipAspect(aspectW, aspectH)
                    val applied = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            setPictureInPictureParams(buildPipParams())
                            true
                        } else {
                            false
                        }
                    } catch (_: Throwable) {
                        false
                    }
                    result.success(applied)
                }
                "enter" -> {
                    if (!isPipSupported()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val aspectW = call.argument<Number>("aspectW")?.toInt() ?: pipAspect.numerator
                    val aspectH = call.argument<Number>("aspectH")?.toInt() ?: pipAspect.denominator
                    pipAspect = clampPipAspect(aspectW, aspectH)
                    val entered = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            enterPictureInPictureMode(buildPipParams())
                        } else {
                            false
                        }
                    } catch (_: Throwable) {
                        false
                    }
                    result.success(entered)
                }
                "exit" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !isPipSupported()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    runOnUiThread {
                        try {
                            startActivity(
                                Intent(this, MainActivity::class.java)
                                    .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                            )
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        pipChannel = pip
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoEnterPip &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            isPipSupported()
        ) {
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Throwable) {
                // 忽略异常，避免切后台时崩溃
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        val channel = pipChannel ?: return
        runOnUiThread {
            try {
                channel.invokeMethod("pipChanged", mapOf("active" to isInPictureInPictureMode))
            } catch (_: Throwable) {
                // 引擎未就绪或通道异常时直接忽略
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        val handled = cameraPlugin?.onRequestPermissionsResult(requestCode) ?: false
        if (!handled) super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        cameraPlugin?.disposePlugin()
        cameraPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        } catch (_: Throwable) {
            false
        }
    }

    private fun clampPipAspect(aspectW: Int, aspectH: Int): Rational {
        if (aspectW <= 0 || aspectH <= 0) return Rational(16, 9)
        val ratio = aspectW.toDouble() / aspectH.toDouble()
        if (!ratio.isFinite()) return Rational(16, 9)
        return when {
            ratio < 0.42 -> Rational(42, 100)
            ratio > 2.39 -> Rational(239, 100)
            else -> Rational(aspectW, aspectH)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(pipAspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnterPip)
        }
        return builder.build()
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
