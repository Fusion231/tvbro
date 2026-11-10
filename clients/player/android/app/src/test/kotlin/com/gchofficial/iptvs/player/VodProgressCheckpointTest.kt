package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VodProgressCheckpointTest {
    private fun VodProgressCheckpoint.report(
        nowMs: Long = 0L,
        openId: Long = 1L,
        live: Boolean = false,
        dvr: Boolean = false,
        positionMs: Long = 10_000L,
        durationMs: Long = 2_400_000L,
        flush: Boolean = false,
    ) = shouldReport(nowMs, openId, live, dvr, positionMs, durationMs, flush)

    @Test
    fun `checkpoints start after ten seconds and follow the thirty second interval`() {
        val checkpoint = VodProgressCheckpoint()
        assertFalse(checkpoint.report(positionMs = 9_999L))
        assertTrue(checkpoint.report())
        assertFalse(checkpoint.report(nowMs = 29_999L, positionMs = 39_999L))
        assertTrue(checkpoint.report(nowMs = 30_000L, positionMs = 40_000L))
    }

    @Test
    fun `live DVR missing session and zero engine positions never create VOD checkpoints`() {
        val checkpoint = VodProgressCheckpoint()
        assertFalse(checkpoint.report(live = true, flush = true))
        assertFalse(checkpoint.report(dvr = true, flush = true))
        assertFalse(checkpoint.report(openId = 0L, flush = true))
        assertFalse(checkpoint.report(durationMs = 0L, flush = true))
        assertFalse(checkpoint.report(positionMs = 0L, flush = true))
        assertTrue(checkpoint.report())
        assertFalse(checkpoint.report(nowMs = 40_000L, positionMs = 0L, flush = true))
    }

    @Test
    fun `sleep flushes the latest position without waiting for the timer`() {
        val checkpoint = VodProgressCheckpoint()
        assertTrue(checkpoint.report())
        assertTrue(checkpoint.report(nowMs = 1_000L, positionMs = 11_000L, flush = true))
        assertFalse(checkpoint.report(nowMs = 1_001L, positionMs = 11_000L, flush = true))
        assertTrue(checkpoint.report(nowMs = 1_500L, positionMs = 11_500L, flush = true))
    }

    @Test
    fun `unchanged periodic sample still gets one lifecycle flush and completed progress survives`() {
        val checkpoint = VodProgressCheckpoint()
        assertTrue(checkpoint.report())
        assertFalse(checkpoint.report(nowMs = 30_000L))
        assertTrue(checkpoint.report(nowMs = 30_001L, flush = true))
        assertFalse(checkpoint.report(nowMs = 30_002L, flush = true))
        assertTrue(checkpoint.report(nowMs = 31_000L, positionMs = 2_400_000L, flush = true))
    }
}
