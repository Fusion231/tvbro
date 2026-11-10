package com.gchofficial.iptvs.player

/** Native VOD activity checkpoints; the Dart host owns durable storage and sync. */
class VodProgressCheckpoint {
    private var lastReportedAtMs: Long? = null
    private var lastPositionMs = -1L
    private var lastDurationMs = -1L
    private var lastFlushed = false

    fun shouldReport(
        nowMs: Long,
        openId: Long,
        isLive: Boolean,
        dvrActive: Boolean,
        positionMs: Long,
        durationMs: Long,
        flush: Boolean = false,
    ): Boolean {
        if (openId <= 0L || isLive || dvrActive || positionMs < 10_000L || durationMs <= 0L) {
            return false
        }
        val unchanged = positionMs == lastPositionMs && durationMs == lastDurationMs
        if (unchanged && (!flush || lastFlushed)) return false
        val previous = lastReportedAtMs
        if (!flush && previous != null && nowMs - previous < INTERVAL_MS) return false
        lastReportedAtMs = nowMs
        lastPositionMs = positionMs
        lastDurationMs = durationMs
        lastFlushed = flush
        return true
    }

    companion object {
        const val INTERVAL_MS = 30_000L
    }
}
