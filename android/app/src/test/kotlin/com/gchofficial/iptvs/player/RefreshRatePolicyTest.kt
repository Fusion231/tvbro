package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RefreshRatePolicyTest {
    @Test fun filmAndTvUseIntegerMultiples() {
        assertEquals(48f, matchingRefreshRate(24f, listOf(48f, 60f, 120f), 60f))
        assertEquals(50f, matchingRefreshRate(25f, listOf(50f, 60f), 60f))
        assertEquals(50f, matchingRefreshRate(50f, listOf(50f, 60f), 60f))
    }

    @Test fun keepsCurrentCompatibleModeInsteadOfFlickering() {
        assertEquals(120f, matchingRefreshRate(24f, listOf(24f, 60f, 120f), 120f))
    }

    @Test fun supportsFractionalRates() {
        assertEquals(59.94f, matchingRefreshRate(29.97f, listOf(50f, 59.94f), 50f))
        assertEquals(59.94f, matchingRefreshRate(59.94f, listOf(50f, 59.94f), 50f))
    }

    @Test fun doesNotForceAnUnsupportedOrUnknownFrameRate() {
        assertNull(matchingRefreshRate(24f, listOf(50f, 60f), 60f))
        assertNull(matchingRefreshRate(0f, listOf(50f), 60f))
        assertNull(matchingRefreshRate(Float.NaN, listOf(50f), 60f))
        assertNull(matchingRefreshRate(50f, emptyList(), 60f))
    }
}
