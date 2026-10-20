package com.firewatch.watchdog.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.hypot

class WatermarkFrameGeometryTest {
    @Test
    fun `portrait back camera maps full display to the cropped buffer`() {
        val geometry = portraitGeometry(mirroring = false)

        assertPoint(geometry.displayToBuffer(0f, 0f), 656f, 1080f)
        assertPoint(geometry.displayToBuffer(1080f, 0f), 656f, 0f)
        assertPoint(geometry.displayToBuffer(0f, 608f), 1264f, 1080f)
    }

    @Test
    fun `portrait front camera mirrors in final display space without moving the card`() {
        val geometry = portraitGeometry(mirroring = true)

        assertPoint(geometry.displayToBuffer(0f, 0f), 656f, 0f)
        assertPoint(geometry.displayToBuffer(1080f, 0f), 656f, 1080f)
        assertPoint(geometry.displayToBuffer(0f, 608f), 1264f, 0f)
    }

    @Test
    fun `landscape and mirrored landscape preserve one to one geometry`() {
        listOf(false, true).forEach { mirroring ->
            val geometry = WatermarkFrameGeometry.create(
                bufferWidth = 1920,
                bufferHeight = 1080,
                cropLeft = 0,
                cropTop = 0,
                cropRight = 1920,
                cropBottom = 1080,
                rotationDegrees = 0,
                mirroring = mirroring,
            )

            assertOneToOne(geometry)
            assertEquals(1920, geometry.displayWidth)
            assertEquals(1080, geometry.displayHeight)
        }
    }

    @Test
    fun `all rotations preserve one to one geometry`() {
        listOf(0, 90, 180, 270).forEach { rotation ->
            listOf(false, true).forEach { mirroring ->
                val geometry = WatermarkFrameGeometry.create(
                    bufferWidth = 1920,
                    bufferHeight = 1080,
                    cropLeft = 656,
                    cropTop = 0,
                    cropRight = 1264,
                    cropBottom = 1080,
                    rotationDegrees = rotation,
                    mirroring = mirroring,
                )

                assertOneToOne(geometry)
                val expectedSwap = rotation == 90 || rotation == 270
                assertEquals(if (expectedSwap) 1080 else 608, geometry.displayWidth)
                assertEquals(if (expectedSwap) 608 else 1080, geometry.displayHeight)
            }
        }
    }

    @Test
    fun `invalid crop safely falls back to the full buffer`() {
        val geometry = WatermarkFrameGeometry.create(
            bufferWidth = 1920,
            bufferHeight = 1080,
            cropLeft = 1400,
            cropTop = 600,
            cropRight = 1300,
            cropBottom = 500,
            rotationDegrees = 90,
            mirroring = false,
        )

        assertEquals(0, geometry.cropLeft)
        assertEquals(0, geometry.cropTop)
        assertEquals(1080, geometry.displayWidth)
        assertEquals(1920, geometry.displayHeight)
    }

    private fun portraitGeometry(mirroring: Boolean): WatermarkFrameGeometry =
        WatermarkFrameGeometry.create(
            bufferWidth = 1920,
            bufferHeight = 1080,
            cropLeft = 656,
            cropTop = 0,
            cropRight = 1264,
            cropBottom = 1080,
            rotationDegrees = 90,
            mirroring = mirroring,
        )

    private fun assertOneToOne(geometry: WatermarkFrameGeometry) {
        val topLeft = geometry.displayToBuffer(0f, 0f)
        val topRight = geometry.displayToBuffer(geometry.displayWidth.toFloat(), 0f)
        val bottomLeft = geometry.displayToBuffer(0f, geometry.displayHeight.toFloat())

        val horizontal = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        val vertical = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        assertEquals(geometry.displayWidth.toFloat(), horizontal, 0.001f)
        assertEquals(geometry.displayHeight.toFloat(), vertical, 0.001f)
        assertTrue(horizontal > 0f)
        assertTrue(vertical > 0f)
    }

    private fun assertPoint(actual: WatermarkPoint, x: Float, y: Float) {
        assertEquals(x, actual.x, 0.001f)
        assertEquals(y, actual.y, 0.001f)
    }
}
