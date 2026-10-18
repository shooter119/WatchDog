package com.firewatch.watchdog.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

/**
 * 定位封装。
 *
 * 刻意不使用 Google Play Services 的 FusedLocationProvider：国产三防机普遍没有 GMS，
 * 依赖它会导致定位直接失效。这里用系统 LocationManager 的 GPS / 网络 / 被动三种来源。
 *
 * 策略：先秒回最近一次已知位置（可能是几分钟前），同时发起一次高精度请求，
 * 8 秒内拿到更准的位置就覆盖。拍摄不必等定位，拿不到就降级为「位置未获取」。
 */
object LocationHelper {

    data class Fix(
        val latitude: Double,
        val longitude: Double,
        val accuracyMeters: Float,
        val provider: String,
        val ageMs: Long,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "lat" to latitude,
            "lon" to longitude,
            "accuracy" to accuracyMeters,
            "provider" to provider,
            "ageMs" to ageMs,
        )
    }

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 获取一次定位。
     * @param timeoutMs 等待更精确位置的上限；到时仍未取到则使用已知位置或返回 null。
     */
    fun current(context: Context, timeoutMs: Long = 8_000, onResult: (Fix?) -> Unit) {
        if (!hasPermission(context)) {
            onResult(null)
            return
        }
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null) {
            onResult(null)
            return
        }

        val cached = lastKnown(manager)
        val handler = Handler(Looper.getMainLooper())
        val finished = booleanArrayOf(false)

        lateinit var listener: LocationListener
        val finish = { fix: Location? ->
            if (!finished[0]) {
                finished[0] = true
                runCatching { manager.removeUpdates(listener) }
                handler.removeCallbacksAndMessages(null)
                val chosen = betterOf(cached, fix)
                onResult(chosen?.let { toFix(it) })
            }
        }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = finish(location)
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }

        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
        if (providers.isEmpty()) {
            onResult(cached?.let { toFix(it) })
            return
        }

        runCatching {
            providers.forEach { provider ->
                manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            }
        }.onFailure {
            onResult(cached?.let { toFix(it) })
            return
        }

        handler.postDelayed({ finish(null) }, timeoutMs)
    }

    /** 按「精度优先，其次新鲜度」在已知位置与最新位置之间择优。 */
    private fun betterOf(cached: Location?, fresh: Location?): Location? {
        if (fresh == null) return cached
        if (cached == null) return fresh
        val freshIsMuchBetter = fresh.accuracy < cached.accuracy * 0.5f
        val cachedIsFresh = System.currentTimeMillis() - cached.time < 60_000
        return if (freshIsMuchBetter || !cachedIsFresh) fresh else cached
    }

    private fun lastKnown(manager: LocationManager): Location? {
        val candidates = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        ).mapNotNull { provider ->
            runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
        }
        return candidates.maxByOrNull { it.time }
    }

    private fun toFix(location: Location): Fix = Fix(
        latitude = location.latitude,
        longitude = location.longitude,
        accuracyMeters = location.accuracy,
        provider = location.provider ?: "unknown",
        ageMs = (System.currentTimeMillis() - location.time).coerceAtLeast(0L),
    )
}
