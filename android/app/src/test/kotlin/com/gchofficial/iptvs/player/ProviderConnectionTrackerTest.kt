package com.gchofficial.iptvs.player

import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderConnectionTrackerTest {
    @Test
    fun `replacement waits for every cancelled HTTP source and resumes once`() {
        val tracker = ProviderConnectionTracker()
        val calls = AtomicInteger()
        tracker.opened(); tracker.opened()
        tracker.whenIdle { calls.incrementAndGet() }
        tracker.closed()
        assertEquals(0, calls.get())
        tracker.closed()
        assertEquals(1, calls.get())
        tracker.opened(); tracker.closed()
        assertEquals(1, calls.get())
        tracker.whenIdle { calls.incrementAndGet() }
        assertEquals(2, calls.get())
    }
}
