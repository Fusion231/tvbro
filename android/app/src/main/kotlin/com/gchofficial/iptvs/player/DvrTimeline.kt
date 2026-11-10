package com.gchofficial.iptvs.player

/** HLS positions can be negative when a paused frame precedes the new window. */
fun dvrTimelinePositionMs(positionMs: Long, windowOffsetMs: Long): Long =
    (positionMs + windowOffsetMs.coerceAtLeast(0L)).coerceAtLeast(0L)
