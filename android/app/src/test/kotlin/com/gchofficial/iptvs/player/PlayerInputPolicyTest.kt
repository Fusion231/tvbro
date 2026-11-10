package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerInputPolicyTest {
    @Test
    fun `volume keys bypass player chrome while navigation retains its policy`() {
        for (keyCode in listOf(24, 25, 164)) {
            assertTrue(PlayerInputPolicy.isSystemVolumeKey(keyCode))
        }
        assertFalse(PlayerInputPolicy.isSystemVolumeKey(23)) // D-pad centre still reveals controls.
        assertFalse(PlayerInputPolicy.isSystemVolumeKey(4)) // Back retains its own policy.
    }

    @Test
    fun `ten second seeks clamp to both VOD boundaries`() {
        assertEquals(0L, PlayerInputPolicy.seekTarget(3_000L, 60_000L, -10_000L))
        assertEquals(60_000L, PlayerInputPolicy.seekTarget(55_000L, 60_000L, 10_000L))
        assertEquals(15_000L, PlayerInputPolicy.seekTarget(25_000L, 60_000L, -10_000L))
        assertEquals(35_000L, PlayerInputPolicy.seekTarget(25_000L, 60_000L, 10_000L))
        assertEquals(35_000L, PlayerInputPolicy.seekTarget(25_000L, 0L, 10_000L))
    }

    @Test
    fun `episode navigation follows supplied order and stops at the ends`() {
        val state = PlayerUiState(title = "Series", isLive = false)
        state.episodes = listOf(TrackOption("season1-final", "S1 E8"), TrackOption("season2-first", "S2 E1"))
        state.currentEpisodeId = "season1-final"
        assertTrue(state.hasEpisodes)
        assertNull(state.previousEpisode)
        assertEquals("season2-first", state.nextEpisode?.id)
        state.currentEpisodeId = "season2-first"
        assertEquals("season1-final", state.previousEpisode?.id)
        assertNull(state.nextEpisode)
        state.currentEpisodeId = "missing"
        assertFalse(state.hasEpisodes)
        assertNull(state.previousEpisode)
        assertNull(state.nextEpisode)
        state.currentEpisodeId = "season1-final"
        state.isLive = true
        assertFalse(state.hasEpisodes)
    }
}
