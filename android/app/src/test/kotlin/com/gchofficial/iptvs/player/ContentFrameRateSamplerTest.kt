package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ContentFrameRateSamplerTest {
    @Test fun droppedFramesDoNotLockA50fpsStreamTo25fps() {
        val sampler = ContentFrameRateSampler()
        // Half the frames reach the screen during a slow fullscreen handoff.
        for (frame in 0..60) {
            assertNull(sampler.sample(frame * 40_000L, frame))
        }
        // Once the decoder recovers, a complete clean sample resolves to 50fps.
        for (frame in 1..29) {
            assertNull(sampler.sample(2_400_000L + frame * 20_000L, 60))
        }
        assertEquals(50f, sampler.sample(3_000_000L, 60))
    }

    @Test fun channelSwitchDiscardsThePreviousRateAndSamples() {
        val sampler = ContentFrameRateSampler()
        for (frame in 0..29) sampler.sample(frame * 40_000L, 0)
        sampler.reset()
        for (frame in 0..29) assertNull(sampler.sample(frame * 20_000L, 0))
        assertEquals(50f, sampler.sample(600_000L, 0))
    }

    @Test fun aGenuine25fpsSourceStillMatches50Hz() {
        val sampler = ContentFrameRateSampler()
        for (frame in 0..29) assertNull(sampler.sample(frame * 40_000L, 0))
        val fps = sampler.sample(1_200_000L, 0)!!
        assertEquals(25f, fps, 0.01f)
        assertEquals(50f, matchingRefreshRate(fps, listOf(50f, 60f), 60f))
    }

    @Test fun unavailableCountersAndDiscontinuitiesCannotConfirmARate() {
        val sampler = ContentFrameRateSampler()
        for (frame in 0..60) assertNull(sampler.sample(frame * 20_000L, -1))
        sampler.reset()
        for (frame in 0..29) sampler.sample(frame * 20_000L, 0)
        assertNull(sampler.sample(2_000_000L, 0))
        for (frame in 1..29) assertNull(sampler.sample(2_000_000L + frame * 20_000L, 0))
        assertEquals(50f, sampler.sample(2_600_000L, 0))
    }
}
