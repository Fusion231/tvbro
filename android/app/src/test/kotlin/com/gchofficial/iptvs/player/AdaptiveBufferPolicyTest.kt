package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AdaptiveBufferPolicyTest {
    @Test
    fun startupBufferingIsIgnoredAndAConfirmedStallPromotesOnce() {
        val policy = AdaptiveBufferPolicy()

        assertNull(policy.observe(0, false, true, false, 0))
        assertNull(policy.observe(5_000, false, true, false, 0))
        assertNull(policy.observe(6_000, true, false, false, 12_000))
        assertNull(policy.observe(6_100, false, true, false, 0))
        assertEquals(
            BufferPreset.HIGH,
            policy.observe(7_100, false, true, false, 0),
        )
        assertNull(policy.observe(30_000, false, true, false, 0))
        assertEquals(BufferPreset.HIGH, policy.effectivePreset)
    }

    @Test
    fun independentStallsPromoteGraduallyAndStopAtMax() {
        val policy = AdaptiveBufferPolicy()
        policy.observe(0, true, false, false, 12_000)
        policy.observe(1_000, false, true, false, 0)
        assertEquals(BufferPreset.HIGH, policy.observe(2_000, false, true, false, 0))

        policy.observe(3_000, true, false, false, 12_000)
        policy.observe(18_000, false, true, false, 0)
        assertEquals(BufferPreset.MAX, policy.observe(19_000, false, true, false, 0))

        policy.observe(20_000, true, false, false, 12_000)
        policy.observe(35_000, false, true, false, 0)
        assertNull(policy.observe(36_000, false, true, false, 0))
        assertEquals(BufferPreset.MAX, policy.effectivePreset)
    }

    @Test
    fun healthyPlaybackReducesOneStepOnlyWithUsableBuffer() {
        val policy = AdaptiveBufferPolicy(BufferPreset.MAX)
        policy.observe(1_000, true, false, false, 12_000)
        assertEquals(BufferPreset.HIGH, policy.observe(91_000, true, false, false, 12_000))
        assertEquals(BufferPreset.NORMAL, policy.observe(181_000, true, false, false, 12_000))
        assertNull(policy.observe(271_000, true, false, false, 5_000))
    }

    @Test
    fun dvrGapDoesNotCountTowardLiveHealthyWindow() {
        val policy = AdaptiveBufferPolicy(BufferPreset.MAX)
        policy.observe(1_000, true, false, false, 12_000)

        policy.resetObservationWindow()

        assertNull(policy.observe(1_000_000, true, false, false, 12_000))
        assertEquals(BufferPreset.MAX, policy.effectivePreset)
        assertNull(policy.observe(1_000_100, true, false, false, 12_000))
        assertEquals(BufferPreset.MAX, policy.effectivePreset)
    }

    @Test
    fun eofDoesNotPromoteAndResetClearsHistory() {
        val policy = AdaptiveBufferPolicy(BufferPreset.HIGH)
        assertNull(policy.observe(1_000, false, false, true, 0))

        policy.reset()

        assertEquals(BufferPreset.NORMAL, policy.effectivePreset)
        assertNull(policy.observe(2_000, false, true, false, 0))
        assertEquals(BufferPreset.NORMAL, policy.effectivePreset)
    }
}
