package com.gchofficial.iptvs.player

/** Keep every relative press while committing one seek after a short quiet gap. */
class SeekBurst {
    private var target: Long? = null
    private var count = 0
    private var firstAt: Long? = null
    private var lastAt: Long? = null
    private var minGap = Long.MAX_VALUE
    private var maxGap = 0L
    val diagnostic: String get() = "keys=$count spanMs=${(lastAt ?: 0L) - (firstAt ?: 0L)} " +
        "minGapMs=${minGap.takeUnless { it == Long.MAX_VALUE } ?: 0L} maxGapMs=$maxGap"
    fun add(positionMs: Long, durationMs: Long, deltaMs: Long, eventTimeMs: Long? = null): Long {
        count++
        eventTimeMs?.let { now ->
            lastAt?.let { before -> minGap = minOf(minGap, now - before); maxGap = maxOf(maxGap, now - before) }
            if (firstAt == null) firstAt = now
            lastAt = now
        }
        return PlayerInputPolicy.seekTarget(target ?: positionMs, durationMs, deltaMs).also { target = it }
    }
    fun take(): Long? { val value = target; clear(); return value }
    fun clear() { target = null; count = 0; firstAt = null; lastAt = null; minGap = Long.MAX_VALUE; maxGap = 0L }
    companion object { const val QUIET_MS = 150L }
}
