package com.firewatch.watchdog.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

/**
 * 定位封装。
 *
 * 刻意不使用 Google Play Services 的 FusedLocationProvider：国产三防机普遍没有 GMS，
 * 依赖它会导致定位直接失效。这里优先结合 Android 系统原生 FUSED（API 31+）/ GPS / 网络 / 被动来源。
 *
 * 策略：
 * - `current()` 收到高精度 GPS/FUSED 新鲜定位立即返回；若首包仅是粗精度网络定位且存在高精度通道，
 *   则保留短收敛窗口（最多 2.8 秒）等待 GPS/FUSED 接管，避免被首次网络回调锁在旧点或粗点；
 * - 对缓存与新定位按新鲜度及精度择优，避免 15 秒以上的旧缓存覆盖用户二次定位的新位置。
 */
object LocationHelper {

    internal const val HIGH_ACCURACY_THRESHOLD_M = 20f
    internal const val CONVERGENCE_GRACE_MS = 2_800L
    internal const val CACHE_RECENT_WINDOW_MS = 15_000L
    internal const val LAST_KNOWN_ACCURACY_WINDOW_MS = 30_000L
    internal const val PROVIDER_FUSED = "fused"
    internal const val PROVIDER_GPS = "gps"
    internal const val PROVIDER_NETWORK = "network"
    internal const val PROVIDER_PASSIVE = "passive"

    internal data class FixSample(
        val latitude: Double,
        val longitude: Double,
        val accuracyMeters: Float,
        val provider: String,
        val timeMs: Long,
    )

    data class Fix(
        val latitude: Double,
        val longitude: Double,
        val accuracyMeters: Float,
        val provider: String,
        val ageMs: Long,
        val bearingDegrees: Float? = null,
    ) {
        fun toMap(): Map<String, Any?> = buildMap {
            put("lat", latitude)
            put("lon", longitude)
            put("accuracy", accuracyMeters)
            put("provider", provider)
            put("ageMs", ageMs)
            if (bearingDegrees != null) {
                put("bearing", bearingDegrees)
            }
        }
    }

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun isServiceEnabled(context: Context): Boolean {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return runCatching { manager.isLocationEnabled }.getOrDefault(false)
        }
        return candidateProviders().any { provider ->
            runCatching { manager.isProviderEnabled(provider) }.getOrDefault(false)
        }
    }

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
        val startedAtMs = System.currentTimeMillis()
        var finished = false
        var graceScheduled = false
        var bestLive: Location? = null

        lateinit var listener: LocationListener
        val finish = {
            if (!finished) {
                finished = true
                runCatching { manager.removeUpdates(listener) }
                handler.removeCallbacksAndMessages(null)
                val nowMs = System.currentTimeMillis()
                val cachedSample = cached?.toSample()
                val freshSample = bestLive?.toSample()
                val winnerSample = chooseFinalFix(cachedSample, freshSample, nowMs)
                val chosen = when {
                    winnerSample == null -> null
                    freshSample != null && winnerSample == freshSample -> bestLive
                    else -> cached
                }
                onResult(chosen?.let { toFix(it) })
            }
        }

        val candidates = candidateProviders()
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
        if (candidates.isEmpty()) {
            onResult(cached?.let { toFix(it) })
            return
        }

        val registered = mutableListOf<String>()
        val graceRunnable = Runnable { finish() }
        val hardTimeoutRunnable = Runnable { finish() }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (finished) return
                val sample = location.toSample()
                if (isBetterCandidate(bestLive?.toSample(), sample)) {
                    bestLive = location
                }
                val currentBest = bestLive ?: return
                val currentSample = currentBest.toSample()
                val waitingForPrecise = registered.any { it != PROVIDER_NETWORK }
                val nowMs = System.currentTimeMillis()
                if (isHighAccuracyFreshFix(currentSample, nowMs) || !waitingForPrecise) {
                    finish()
                } else if (!graceScheduled) {
                    graceScheduled = true
                    val elapsedMs = (nowMs - startedAtMs).coerceAtLeast(0L)
                    val remainingMs = (timeoutMs - elapsedMs).coerceAtLeast(0L)
                    handler.postDelayed(graceRunnable, minOf(CONVERGENCE_GRACE_MS, remainingMs))
                }
            }

            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }

        candidates.forEach { provider ->
            val ok = runCatching {
                manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            }.isSuccess
            if (ok) {
                registered.add(provider)
            }
        }

        if (registered.isEmpty()) {
            runCatching { manager.removeUpdates(listener) }
            onResult(cached?.let { toFix(it) })
            return
        }

        handler.postDelayed(hardTimeoutRunnable, timeoutMs)
    }

    /**
     * 启动连续定位监听。
     * 先立即回调最近一次已知位置，再持续分发高精度更新，调用返回闭包后立即释放硬件监听。
     */
    fun watch(
        context: Context,
        minTimeMs: Long = 1_500L,
        minDistanceM: Float = 1.0f,
        onFix: (Fix) -> Unit,
    ): () -> Unit {
        if (!hasPermission(context)) return {}
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return {}

        var active = true
        var lastAccepted: Location? = lastKnown(manager)?.also { cached ->
            onFix(toFix(cached))
        }

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (!active) return
                if (!shouldAcceptLiveFix(lastAccepted, location)) return
                lastAccepted = location
                onFix(toFix(location))
            }

            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }

        val providers = candidateProviders()
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
        if (providers.isEmpty()) return {}

        var registeredCount = 0
        providers.forEach { provider ->
            val interval = if (provider == PROVIDER_NETWORK) {
                maxOf(minTimeMs, 3_000L)
            } else {
                minTimeMs
            }
            val distance = if (provider == PROVIDER_NETWORK) {
                maxOf(minDistanceM, 2.0f)
            } else {
                minDistanceM
            }
            val ok = runCatching {
                manager.requestLocationUpdates(
                    provider,
                    interval,
                    distance,
                    listener,
                    Looper.getMainLooper(),
                )
            }.isSuccess
            if (ok) registeredCount += 1
        }

        if (registeredCount == 0) {
            runCatching { manager.removeUpdates(listener) }
            return {}
        }

        return {
            if (active) {
                active = false
                runCatching { manager.removeUpdates(listener) }
            }
        }
    }

    /** 抑制已有高精度 GPS 时的粗糙网络定位闪跳，并过滤陈旧回退位置。 */
    internal fun shouldAcceptLiveFix(last: Location?, incoming: Location): Boolean {
        if (last == null) return true
        if (incoming.time > 0L && last.time > 0L && incoming.time + 5_000L < last.time) {
            return false
        }
        val lastIsRecentGps =
            (last.provider == PROVIDER_GPS || last.provider == PROVIDER_FUSED) &&
                (incoming.time - last.time).coerceAtLeast(0L) < 10_000L
        val incomingIsCoarseNetwork =
            incoming.provider == PROVIDER_NETWORK &&
                incoming.accuracy > last.accuracy * 1.5f + 15f
        if (lastIsRecentGps && incomingIsCoarseNetwork) {
            return false
        }
        return true
    }

    internal fun normalizedAccuracy(accuracyMeters: Float): Float =
        if (accuracyMeters.isFinite() && accuracyMeters > 0f) accuracyMeters else Float.MAX_VALUE

    internal fun isHighAccuracyFreshFix(
        sample: FixSample,
        nowMs: Long = sample.timeMs,
    ): Boolean {
        if (sample.provider == PROVIDER_NETWORK) return false
        val ageMs = if (sample.timeMs > 0L && nowMs > 0L) (nowMs - sample.timeMs).coerceAtLeast(0L) else 0L
        if (ageMs > 10_000L) return false
        return normalizedAccuracy(sample.accuracyMeters) <= HIGH_ACCURACY_THRESHOLD_M
    }

    internal fun isBetterCandidate(currentBest: FixSample?, incoming: FixSample): Boolean {
        if (currentBest == null) return true
        if (incoming.timeMs > 0L && currentBest.timeMs > 0L && incoming.timeMs + 5_000L < currentBest.timeMs) {
            return false
        }
        val incomingAcc = normalizedAccuracy(incoming.accuracyMeters)
        val bestAcc = normalizedAccuracy(currentBest.accuracyMeters)
        if (incomingAcc + 2f < bestAcc) return true
        if (bestAcc + 2f < incomingAcc) return false
        val currentIsNetwork = currentBest.provider == PROVIDER_NETWORK
        val incomingIsNetwork = incoming.provider == PROVIDER_NETWORK
        if (currentIsNetwork != incomingIsNetwork) return !incomingIsNetwork
        return incoming.timeMs >= currentBest.timeMs
    }

    /**
     * 在缓存定位与本次新收敛定位之间择优：
     * - 缓存超过 15 秒时优先采信新定位（防止用户在移动后二次定位被旧缓存覆盖）；
     * - 15 秒内的极新缓存仅当新回调明显精度恶化（> 缓存 2 倍 + 20m 且超过 20m）时回退缓存。
     */
    internal fun chooseFinalFix(
        cached: FixSample?,
        fresh: FixSample?,
        nowMs: Long = System.currentTimeMillis(),
    ): FixSample? {
        if (fresh == null) return cached
        if (cached == null) return fresh
        if (fresh.timeMs > 0L && cached.timeMs > 0L && fresh.timeMs + 5_000L < cached.timeMs) {
            return cached
        }
        val cacheAgeMs = if (cached.timeMs > 0L) (nowMs - cached.timeMs).coerceAtLeast(0L) else Long.MAX_VALUE
        if (cacheAgeMs > CACHE_RECENT_WINDOW_MS) {
            return fresh
        }
        val freshAcc = normalizedAccuracy(fresh.accuracyMeters)
        val cachedAcc = normalizedAccuracy(cached.accuracyMeters)
        if (freshAcc <= HIGH_ACCURACY_THRESHOLD_M || freshAcc <= cachedAcc * 2f + 20f) {
            return fresh
        }
        return cached
    }

    internal fun chooseBestLastKnown(
        candidates: List<FixSample>,
        nowMs: Long = System.currentTimeMillis(),
    ): FixSample? {
        if (candidates.isEmpty()) return null
        val recent = candidates.filter { sample ->
            sample.timeMs > 0L && (nowMs - sample.timeMs).coerceAtLeast(0L) <= LAST_KNOWN_ACCURACY_WINDOW_MS
        }
        if (recent.isNotEmpty()) {
            return recent.reduce { best, incoming ->
                if (isBetterCandidate(best, incoming)) incoming else best
            }
        }
        return candidates.maxByOrNull { it.timeMs }
    }

    private fun candidateProviders(): List<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(LocationManager.FUSED_PROVIDER)
        }
        add(LocationManager.GPS_PROVIDER)
        add(LocationManager.NETWORK_PROVIDER)
    }

    private fun lastKnown(manager: LocationManager): Location? {
        val providers = candidateProviders() + LocationManager.PASSIVE_PROVIDER
        val locations = providers.distinct().mapNotNull { provider ->
            runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
        }
        if (locations.isEmpty()) return null
        val samples = locations.map { it.toSample() }
        val chosen = chooseBestLastKnown(samples) ?: return locations.maxByOrNull { it.time }
        val index = samples.indexOf(chosen)
        return if (index >= 0) locations[index] else locations.maxByOrNull { it.time }
    }

    private fun Location.toSample(): FixSample = FixSample(
        latitude = latitude,
        longitude = longitude,
        accuracyMeters = accuracy,
        provider = provider ?: "unknown",
        timeMs = time,
    )

    private fun toFix(location: Location): Fix = Fix(
        latitude = location.latitude,
        longitude = location.longitude,
        accuracyMeters = location.accuracy,
        provider = location.provider ?: "unknown",
        ageMs = (System.currentTimeMillis() - location.time).coerceAtLeast(0L),
        bearingDegrees = if (location.hasBearing() && location.bearing.isFinite()) {
            location.bearing
        } else {
            null
        },
    )
}
