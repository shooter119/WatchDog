package com.firewatch.watchdog.camera

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class GalleryPairTransactionTest {
    @Test
    fun `publishes both new entries and keeps reused entries untouched`() {
        val operations = mutableListOf<String>()

        val pair = GalleryPairTransaction.save(
            prepareWatermarked = {
                GalleryPairTransaction.Prepared("wm", created = true)
            },
            prepareSource = {
                GalleryPairTransaction.Prepared("raw", created = false)
            },
            publish = { operations += "publish:$it" },
            rollback = { operations += "rollback:$it" },
        )

        assertEquals("wm" to "raw", pair)
        assertEquals(listOf("publish:wm"), operations)
    }

    @Test
    fun `rolls back earlier entry when source creation fails`() {
        val operations = mutableListOf<String>()

        assertThrows(IllegalStateException::class.java) {
            GalleryPairTransaction.save(
                prepareWatermarked = {
                    GalleryPairTransaction.Prepared("wm", created = true)
                },
                prepareSource = {
                    error("raw failed")
                },
                publish = { operations += "publish:$it" },
                rollback = { operations += "rollback:$it" },
            )
        }

        assertEquals(listOf("rollback:wm"), operations)
    }

    @Test
    fun `rolls back in reverse order when publishing the source fails`() {
        val operations = mutableListOf<String>()

        assertThrows(IllegalStateException::class.java) {
            GalleryPairTransaction.save(
                prepareWatermarked = {
                    GalleryPairTransaction.Prepared("wm", created = true)
                },
                prepareSource = {
                    GalleryPairTransaction.Prepared("raw", created = true)
                },
                publish = {
                    if (it == "raw") error("publish failed")
                    operations += "publish:$it"
                },
                rollback = { operations += "rollback:$it" },
            )
        }

        assertEquals(
            listOf("publish:wm", "rollback:raw", "rollback:wm"),
            operations,
        )
    }

    @Test
    fun `names watermarked and source files with stable Chinese suffixes`() {
        val photo = File("/capture/SRC_IMG_20261020_083900_123.jpg")
        val video = File("/capture/VID_20261020_083900_123_WM.mp4")

        assertEquals(
            "IMG_20261020_083900_123_带水印.jpg",
            GalleryNaming.displayName(photo, video = false, watermarked = true),
        )
        assertEquals(
            "IMG_20261020_083900_123_无水印.jpg",
            GalleryNaming.displayName(photo, video = false, watermarked = false),
        )
        assertEquals(
            "VID_20261020_083900_123_带水印.mp4",
            GalleryNaming.displayName(video, video = true, watermarked = true),
        )
        assertEquals(
            "VID_20261020_083900_123_无水印.mp4",
            GalleryNaming.displayName(video, video = true, watermarked = false),
        )
    }
}
