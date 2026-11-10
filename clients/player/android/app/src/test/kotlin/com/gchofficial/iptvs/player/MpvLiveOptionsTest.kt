package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvLiveOptionsTest {
    /**
     * Regression guard: `reconnect_at_eof` makes ffmpeg treat an HLS manifest's
     * finite EOF as an error and reconnect forever, so the demuxer probe never
     * completes and the stream never opens. It shipped here once; keep it out.
     */
    @Test
    fun `stream-lavf-o never enables reconnect_at_eof`() {
        assertFalse(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_at_eof"))
    }

    @Test
    fun `stream-lavf-o leaves retries to the finite host budget`() {
        assertTrue(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect=0"))
        assertTrue(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_streamed=0"))
    }

    @Test
    fun `HLS prefetch cannot bypass the segment retry limit`() {
        assertTrue(MpvLiveOptions.DEMUXER_LAVF_O.contains("seg_max_retry=0"))
        assertTrue(MpvLiveOptions.DEMUXER_LAVF_O.contains("http_multiple=0"))
    }

    /**
     * The stall watchdog can only reload a dead connection if ffmpeg gives up on
     * it first, so the network timeout has to stay well under the backoff.
     */
    @Test
    fun `network timeout stays below the stall reconnect threshold`() {
        val timeoutMs = MpvLiveOptions.NETWORK_TIMEOUT.toLong() * 1000
        assertTrue(timeoutMs < ReconnectPolicy.MAX_BACKOFF_MS)
    }
}
