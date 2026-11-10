package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Test

class DvrTimelineTest {
    @Test fun cursorSurvivesMultipleHlsWindowSlides() {
        assertEquals(11_500L, dvrTimelinePositionMs(11_500L, 0L))
        assertEquals(12_500L, dvrTimelinePositionMs(6_500L, 6_000L))
        assertEquals(25_000L, dvrTimelinePositionMs(7_000L, 18_000L))
    }

    @Test fun initialUnsetOffsetsCannotMoveTheCursorBeforeZero() {
        assertEquals(0L, dvrTimelinePositionMs(-1L, Long.MIN_VALUE))
    }

    @Test fun pausedFrameBeforeTheMovingWindowKeepsItsAbsolutePosition() {
        assertEquals(43_320L, dvrTimelinePositionMs(3_320L, 40_000L))
        assertEquals(43_320L, dvrTimelinePositionMs(-43_680L, 87_000L))
    }
}
