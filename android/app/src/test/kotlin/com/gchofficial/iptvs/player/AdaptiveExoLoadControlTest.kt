package com.gchofficial.iptvs.player

import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AdaptiveExoLoadControlTest {
    @Test
    fun `fullscreen can apply a different manual preset to the preview load control`() {
        val control = AdaptiveExoLoadControl(BufferPreset.NORMAL, adaptive = false)

        control.setAdaptiveBuffer(false, BufferPreset.HIGH, reset = true)

        assertEquals(BufferPreset.HIGH, control.effectivePreset())
        assertFalse(control.setAdaptivePreset(BufferPreset.MAX))
    }

    @Test
    fun `adopting with Auto retains the normal startup preset`() {
        val control = AdaptiveExoLoadControl(BufferPreset.MAX, adaptive = false)

        control.setAdaptiveBuffer(true, BufferPreset.MAX, reset = true)

        assertEquals(BufferPreset.NORMAL, control.effectivePreset())
    }

    private fun parameters(
        bufferedMs: Long,
        rebuffering: Boolean = true,
        liveOffsetMs: Long = C.TIME_UNSET,
        speed: Float = 1f,
    ) = LoadControl.Parameters(
        PlayerId.UNSET, Timeline.EMPTY, MediaPeriodId(Any()), 0,
        bufferedMs * 1_000, speed, true, rebuffering,
        if (liveOffsetMs == C.TIME_UNSET) C.TIME_UNSET else liveOffsetMs * 1_000,
        C.TIME_UNSET,
    )

    @Test
    fun `Auto waits for a recovery cushion but keeps fast startup`() {
        val control = AdaptiveExoLoadControl(BufferPreset.NORMAL, adaptive = true)
        control.onPrepared(PlayerId.UNSET)
        assertTrue(control.shouldStartPlayback(parameters(1_000, rebuffering = false)))
        assertFalse(control.shouldStartPlayback(parameters(1_999)))
        assertTrue(control.shouldStartPlayback(parameters(2_000)))
        control.setAdaptivePreset(BufferPreset.HIGH)
        assertTrue(control.shouldStartPlayback(parameters(1_000, rebuffering = false)))
        assertFalse(control.shouldStartPlayback(parameters(2_999)))
        assertTrue(control.shouldStartPlayback(parameters(3_000)))
        control.setAdaptivePreset(BufferPreset.MAX)
        assertFalse(control.shouldStartPlayback(parameters(3_999)))
        assertTrue(control.shouldStartPlayback(parameters(4_000)))
        control.setAdaptivePreset(BufferPreset.NORMAL)
        assertTrue(control.shouldStartPlayback(parameters(2_000)))
        control.onReleased(PlayerId.UNSET)
    }

    @Test
    fun `deep recovery still respects live offset and playback speed`() {
        val control = AdaptiveExoLoadControl(BufferPreset.MAX, adaptive = false)
        control.onPrepared(PlayerId.UNSET)
        assertFalse(control.shouldStartPlayback(parameters(1_999, liveOffsetMs = 4_000)))
        assertTrue(control.shouldStartPlayback(parameters(2_000, liveOffsetMs = 4_000)))
        assertFalse(control.shouldStartPlayback(parameters(4_000, speed = 2f)))
        assertTrue(control.shouldStartPlayback(parameters(8_000, speed = 2f)))
        control.onReleased(PlayerId.UNSET)
    }

    @Test
    fun `manual recovery gates keep margin below reconnect watchdog`() {
        for ((preset, thresholdMs) in listOf(
            BufferPreset.LOW to 1_500L,
            BufferPreset.NORMAL to 2_000L,
            BufferPreset.HIGH to 3_000L,
            BufferPreset.MAX to 4_000L,
        )) {
            val control = AdaptiveExoLoadControl(preset, adaptive = false)
            control.onPrepared(PlayerId.UNSET)
            assertFalse(control.shouldStartPlayback(parameters(thresholdMs - 1)))
            assertTrue(control.shouldStartPlayback(parameters(thresholdMs)))
            assertTrue(thresholdMs * 2 <= ReconnectPolicy.STALL_RECONNECT_MS)
            control.onReleased(PlayerId.UNSET)
        }
    }
}
