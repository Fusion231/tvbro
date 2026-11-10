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

    @Test
    fun shortStallBurstsPromoteOnceAndRespectCooldown() {
        val policy = AdaptiveBufferPolicy()
        fun sample(at: Long, stalled: Boolean) =
            policy.observe(at, !stalled, stalled, false, if (stalled) 0 else 12_000)
        sample(0, false)
        sample(1_000, true)
        assertNull(sample(1_100, true))
        sample(1_200, false)
        assertNull(sample(3_000, true))
        sample(3_200, false)
        assertEquals(BufferPreset.HIGH, sample(5_000, true))
        sample(5_200, false)
        for (at in listOf(6_000L, 8_000L, 10_000L)) {
            assertNull(sample(at, true))
            sample(at + 200, false)
        }
        assertEquals(BufferPreset.MAX, sample(20_000, true))
        assertNull(sample(40_000, true))
    }

    @Test
    fun expiredStallsAndResetHistoryDoNotPromote() {
        val policy = AdaptiveBufferPolicy()
        fun sample(at: Long, stalled: Boolean) =
            policy.observe(at, !stalled, stalled, false, if (stalled) 0 else 12_000)
        sample(0, false)
        sample(1_000, true)
        sample(1_200, false)
        sample(3_000, true)
        sample(3_200, false)
        assertNull(sample(34_000, true))
        sample(34_200, false)
        policy.resetObservationWindow()
        sample(35_000, false)
        assertNull(sample(36_000, true))
    }
}
