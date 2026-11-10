package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackCompletionTest {
    @Test
    fun `stop and error do not become episode EOF and each real load ends once`() {
        val completion = PlaybackCompletion()
        assertFalse(completion.ended(true))
        completion.beginLoad()
        assertFalse(completion.ended(false))
        assertTrue(completion.ended(true))
        assertFalse(completion.ended(true))
        completion.beginLoad()
        completion.stop()
        assertFalse(completion.ended(true))
        completion.beginLoad()
        assertTrue(completion.ended(true))
    }

    @Test
    fun `paused seek does not complete but replay can end again`() {
        val completion = PlaybackCompletion()
        completion.beginLoad()
        assertFalse(completion.ended(false))
        assertTrue(completion.ended(true))
        completion.seekBeforeEnd()
        assertTrue(completion.ended(true))
        completion.stop()
        completion.seekBeforeEnd()
        assertFalse(completion.ended(true))
    }

    @Test
    fun `an explicit seek to EOF never selects the next episode`() {
        val completion = PlaybackCompletion()
        completion.beginLoad()
        completion.seekToEnd()
        assertFalse(completion.ended(true))
        completion.seekBeforeEnd()
        assertTrue(completion.ended(true))
    }
}
