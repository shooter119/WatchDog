package com.firewatch.watchdog.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationHelperDecisionTest {

    @Test
    fun `isHighAccuracyFreshFix rejects network and stale fixes`() {
        val now = 1_000_000L
        assertTrue(
            LocationHelper.isHighAccuracyFreshFix(
                LocationHelper.FixSample(29.03, 119.18, 12f, LocationHelper.PROVIDER_GPS, now - 500),
                nowMs = now,
            ),
        )
        assertTrue(
            LocationHelper.isHighAccuracyFreshFix(
                LocationHelper.FixSample(29.03, 119.18, 18f, LocationHelper.PROVIDER_FUSED, now - 1_000),
                nowMs = now,
            ),
        )
        assertFalse(
            LocationHelper.isHighAccuracyFreshFix(
                LocationHelper.FixSample(29.03, 119.18, 10f, LocationHelper.PROVIDER_NETWORK, now),
                nowMs = now,
            ),
        )
        assertFalse(
            LocationHelper.isHighAccuracyFreshFix(
                LocationHelper.FixSample(29.03, 119.18, 35f, LocationHelper.PROVIDER_GPS, now),
                nowMs = now,
            ),
        )
        assertFalse(
            LocationHelper.isHighAccuracyFreshFix(
                LocationHelper.FixSample(29.03, 119.18, 5f, LocationHelper.PROVIDER_GPS, now - 25_000),
                nowMs = now,
            ),
        )
    }

    @Test
    fun `isBetterCandidate lets converging GPS beat initial coarse network fix`() {
        val net = LocationHelper.FixSample(29.030, 119.180, 85f, LocationHelper.PROVIDER_NETWORK, 10_000L)
        val gps = LocationHelper.FixSample(29.032, 119.183, 9f, LocationHelper.PROVIDER_GPS, 11_200L)
        assertTrue(LocationHelper.isBetterCandidate(net, gps))
        assertFalse(LocationHelper.isBetterCandidate(gps, net))
    }

    @Test
    fun `isBetterCandidate prefers non-network when accuracies are close`() {
        val net = LocationHelper.FixSample(29.030, 119.180, 14f, LocationHelper.PROVIDER_NETWORK, 10_000L)
        val fused = LocationHelper.FixSample(29.031, 119.181, 15f, LocationHelper.PROVIDER_FUSED, 10_500L)
        assertTrue(LocationHelper.isBetterCandidate(net, fused))
        assertFalse(LocationHelper.isBetterCandidate(fused, net))
    }

    @Test
    fun `chooseFinalFix does not discard fresh relocate fix after moving beyond 15s`() {
        val now = 100_000L
        val oldPointA = LocationHelper.FixSample(29.030, 119.180, 15f, LocationHelper.PROVIDER_GPS, now - 40_000L)
        val freshPointB = LocationHelper.FixSample(29.045, 119.195, 12f, LocationHelper.PROVIDER_GPS, now)
        assertEquals(freshPointB, LocationHelper.chooseFinalFix(oldPointA, freshPointB, now))

        val freshCoursePointB = LocationHelper.FixSample(29.045, 119.195, 35f, LocationHelper.PROVIDER_NETWORK, now)
        assertEquals(freshCoursePointB, LocationHelper.chooseFinalFix(oldPointA, freshCoursePointB, now))
    }

    @Test
    fun `chooseFinalFix keeps very recent high precision cache if fresh is severely coarse`() {
        val now = 100_000L
        val veryRecentGps = LocationHelper.FixSample(29.030, 119.180, 6f, LocationHelper.PROVIDER_GPS, now - 4_000L)
        val coarseNetwork = LocationHelper.FixSample(29.033, 119.182, 300f, LocationHelper.PROVIDER_NETWORK, now)
        assertEquals(veryRecentGps, LocationHelper.chooseFinalFix(veryRecentGps, coarseNetwork, now))

        val freshBetterNetwork = LocationHelper.FixSample(29.031, 119.181, 18f, LocationHelper.PROVIDER_NETWORK, now)
        assertEquals(freshBetterNetwork, LocationHelper.chooseFinalFix(veryRecentGps, freshBetterNetwork, now))
    }

    @Test
    fun `chooseFinalFix ignores replayed fix older than cached location`() {
        val now = 100_000L
        val cached = LocationHelper.FixSample(29.031, 119.181, 20f, LocationHelper.PROVIDER_GPS, now - 2_000L)
        val replayed = LocationHelper.FixSample(29.020, 119.170, 5f, LocationHelper.PROVIDER_GPS, now - 30_000L)
        assertEquals(cached, LocationHelper.chooseFinalFix(cached, replayed, now))
        assertEquals(cached, LocationHelper.chooseFinalFix(cached, null, now))
        assertNull(LocationHelper.chooseFinalFix(null, null, now))
    }

    @Test
    fun `chooseBestLastKnown picks high accuracy within 30s over slightly newer coarse passive fix`() {
        val now = 200_000L
        val recentGps = LocationHelper.FixSample(29.031, 119.181, 8f, LocationHelper.PROVIDER_GPS, now - 5_000L)
        val newerPassive = LocationHelper.FixSample(29.035, 119.185, 500f, LocationHelper.PROVIDER_PASSIVE, now - 1_000L)
        assertEquals(recentGps, LocationHelper.chooseBestLastKnown(listOf(recentGps, newerPassive), now))
    }
}
