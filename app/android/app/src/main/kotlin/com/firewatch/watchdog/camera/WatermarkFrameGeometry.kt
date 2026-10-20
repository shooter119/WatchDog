package com.firewatch.watchdog.camera

internal data class WatermarkPoint(
    val x: Float,
    val y: Float,
)

/**
 * Maps a watermark bitmap in final display coordinates back to the CameraX buffer.
 *
 * CameraX applies crop -> clockwise rotation -> horizontal mirroring before display.
 * The overlay is composited in buffer coordinates, so this mapping is the inverse of
 * that pipeline. Keeping the bitmap in final display coordinates guarantees the card
 * and its text are only rotated/reflected, never stretched.
 */
internal class WatermarkFrameGeometry private constructor(
    val cropLeft: Int,
    val cropTop: Int,
    val cropWidth: Int,
    val cropHeight: Int,
    val rotationDegrees: Int,
    val mirroring: Boolean,
) {
    val displayWidth: Int =
        if (rotationDegrees == 90 || rotationDegrees == 270) cropHeight else cropWidth

    val displayHeight: Int =
        if (rotationDegrees == 90 || rotationDegrees == 270) cropWidth else cropHeight

    fun displayToBuffer(x: Float, y: Float): WatermarkPoint {
        val rotatedX = if (mirroring) displayWidth - x else x
        return when (rotationDegrees) {
            0 -> WatermarkPoint(
                cropLeft + rotatedX,
                cropTop + y,
            )
            90 -> WatermarkPoint(
                cropLeft + y,
                cropTop + cropHeight - rotatedX,
            )
            180 -> WatermarkPoint(
                cropLeft + cropWidth - rotatedX,
                cropTop + cropHeight - y,
            )
            270 -> WatermarkPoint(
                cropLeft + cropWidth - y,
                cropTop + rotatedX,
            )
            else -> error("Unsupported rotation: $rotationDegrees")
        }
    }

    /** Clockwise triangle preserving the display bitmap's orientation. */
    fun sourcePoints(): FloatArray = floatArrayOf(
        0f, 0f,
        displayWidth.toFloat(), 0f,
        0f, displayHeight.toFloat(),
    )

    /** Buffer positions for [sourcePoints]. */
    fun destinationPoints(): FloatArray {
        val topLeft = displayToBuffer(0f, 0f)
        val topRight = displayToBuffer(displayWidth.toFloat(), 0f)
        val bottomLeft = displayToBuffer(0f, displayHeight.toFloat())
        return floatArrayOf(
            topLeft.x, topLeft.y,
            topRight.x, topRight.y,
            bottomLeft.x, bottomLeft.y,
        )
    }

    companion object {
        fun create(
            bufferWidth: Int,
            bufferHeight: Int,
            cropLeft: Int,
            cropTop: Int,
            cropRight: Int,
            cropBottom: Int,
            rotationDegrees: Int,
            mirroring: Boolean,
        ): WatermarkFrameGeometry {
            require(bufferWidth > 0 && bufferHeight > 0)
            val left = cropLeft.coerceIn(0, bufferWidth)
            val top = cropTop.coerceIn(0, bufferHeight)
            val right = cropRight.coerceIn(left, bufferWidth)
            val bottom = cropBottom.coerceIn(top, bufferHeight)
            val hasCrop = right - left > 1 && bottom - top > 1
            return WatermarkFrameGeometry(
                cropLeft = if (hasCrop) left else 0,
                cropTop = if (hasCrop) top else 0,
                cropWidth = if (hasCrop) right - left else bufferWidth,
                cropHeight = if (hasCrop) bottom - top else bufferHeight,
                rotationDegrees = ((rotationDegrees % 360) + 360) % 360,
                mirroring = mirroring,
            )
        }
    }
}
