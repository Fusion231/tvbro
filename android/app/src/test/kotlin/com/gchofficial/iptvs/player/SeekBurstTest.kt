package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SeekBurstTest {
    @Test
    fun `twenty presses accumulate without depending on decoder position callbacks`() {
        val burst = SeekBurst()
        repeat(20) { burst.add(30_000L, 480_000L, 10_000L, it * 75L) }
        assertEquals("keys=20 spanMs=1425 minGapMs=75 maxGapMs=75", burst.diagnostic)
        assertEquals(230_000L, burst.take())
        assertNull(burst.take())
    }

    @Test
    fun `end clamps and opposite presses remain reversible while pending`() {
        val burst = SeekBurst()
        repeat(20) { burst.add(465_000L, 480_000L, 10_000L) }
        assertEquals(470_000L, burst.add(465_000L, 480_000L, -10_000L))
        burst.clear()
        assertNull(burst.take())
        assertEquals(10_000L, burst.add(0L, 480_000L, 10_000L))
    }
}
