package com.gchofficial.iptvs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppInactivityPolicyTest {
    private val main = "flutter"
    private val player = "fullscreen"
    private val timeout = AppInactivityPolicy.TIMEOUT_MS

    @Test
    fun `short background return preserves the session and ten minutes resets once`() {
        val policy = AppInactivityPolicy()
        policy.activityStarted(main, 0L, 1)
        policy.activityStopped(main, 100L, 1, false)
        policy.activityStarted(main, timeout + 99L, 1)
        assertFalse(policy.consumeReset())
        policy.activityStopped(main, timeout + 200L, 1, false)
        policy.activityStarted(main, 2 * timeout + 200L, 1)
        assertTrue(policy.consumeReset())
        assertFalse(policy.consumeReset())
        assertEquals(1L, policy.snapshot.generation)
    }

    @Test
    fun `native fullscreen does not count as background while Flutter is stopped`() {
        val policy = AppInactivityPolicy()
        policy.activityStarted(main, 0L, 1)
        policy.activityStarted(player, 1L, 1)
        policy.activityStopped(main, 2L, 1, false)
        assertFalse(policy.checkExpiry(10 * timeout, 1))
        policy.activityStarted(main, 10 * timeout, 1)
        policy.activityStopped(player, 10 * timeout + 1, 1, false)
        assertNull(policy.snapshot.backgroundAtMs)
        assertFalse(policy.consumeReset())
    }

    @Test
    fun `visible PiP remains active even when firmware stops its Activity`() {
        val policy = AppInactivityPolicy()
        policy.activityStarted(player, 0L, 1)
        policy.pictureInPictureChanged(player, true, 1L, 1)
        policy.activityStopped(player, 2L, 1, false)
        assertFalse(policy.checkExpiry(10 * timeout, 1))
        policy.pictureInPictureChanged(player, false, 10 * timeout, 1)
        assertEquals(10 * timeout, policy.snapshot.backgroundAtMs)
        assertTrue(policy.checkExpiry(11 * timeout, 1))
    }

    @Test
    fun `destroying a closed PiP removes its visibility exemption`() {
        val policy = AppInactivityPolicy()
        policy.activityStarted(player, 0L, 1)
        policy.pictureInPictureChanged(player, true, 1L, 1)
        policy.activityStopped(player, 2L, 1, false)
        policy.activityDestroyed(player, 3L, 1, false)
        assertTrue(policy.checkExpiry(timeout + 3L, 1))
    }

    @Test
    fun `configuration changes and duplicate stop callbacks do not extend inactivity`() {
        val policy = AppInactivityPolicy()
        policy.activityStarted(main, 0L, 1)
        policy.activityStopped(main, 1L, 1, true)
        policy.activityDestroyed(main, 2L, 1, true)
        assertNull(policy.snapshot.backgroundAtMs)
        policy.activityStarted("recreated", 3L, 1)
        policy.activityStopped("recreated", 4L, 1, false)
        policy.activityDestroyed("recreated", 10L, 1, false)
        assertEquals(4L, policy.snapshot.backgroundAtMs)
        assertTrue(policy.checkExpiry(timeout + 4L, 1))
    }

    @Test
    fun `background snapshot survives process death and expires before player recreation`() {
        val before = AppInactivityPolicy()
        before.activityStarted(player, 0L, 1)
        before.activityStopped(player, 5L, 1, false)
        val restored = AppInactivityPolicy(before.snapshot)
        assertTrue(restored.checkExpiry(timeout + 5L, 1))
        assertTrue(restored.consumeReset())
        // Consuming the UI signal does not make an old retained player Intent valid.
        assertEquals(1L, restored.snapshot.generation)
        assertFalse(restored.checkExpiry(timeout + 6L, 1))
    }

    @Test
    fun `short process recreation preserves playback but reboot rejects the old session`() {
        val saved = AppInactivityPolicy.Snapshot(backgroundAtMs = 100L, bootCount = 1)
        assertFalse(AppInactivityPolicy(saved).checkExpiry(101L, 1))
        assertTrue(AppInactivityPolicy(saved).checkExpiry(101L, 2))
        assertTrue(AppInactivityPolicy(saved).checkExpiry(99L, 1))
    }
}
