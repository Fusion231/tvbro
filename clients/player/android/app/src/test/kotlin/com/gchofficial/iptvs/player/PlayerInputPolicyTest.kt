package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerInputPolicyTest {
    @Test
    fun `transport keys bypass reveal only handling but navigation still reveals`() {
        for (key in listOf(85, 126, 127, 89, 90)) assertTrue(PlayerInputPolicy.isMediaTransportKey(key))
        for (key in listOf(19, 20, 21, 22, 23, 4, 24)) assertFalse(PlayerInputPolicy.isMediaTransportKey(key))
    }
    @Test
    fun `repeated EOF seeks are noops but backward and initial end seeks remain valid`() {
        assertTrue(PlayerInputPolicy.redundantSeek(480_000L, 480_000L, 480_000L, true))
        assertTrue(PlayerInputPolicy.redundantSeek(479_900L, 480_000L, 480_000L, false))
        assertFalse(PlayerInputPolicy.redundantSeek(465_000L, 480_000L, 480_000L, false))
        assertFalse(PlayerInputPolicy.redundantSeek(480_000L, 480_000L, 470_000L, true))
        assertFalse(PlayerInputPolicy.redundantSeek(30_000L, 0L, 40_000L, false))
    }
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
        state.episodes = listOf(EpisodeOption("season1-final", "S1 E8"), EpisodeOption("season2-first", "S2 E1"))
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
