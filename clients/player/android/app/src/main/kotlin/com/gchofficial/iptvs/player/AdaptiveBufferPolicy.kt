package com.gchofficial.iptvs.player

/**
 * Bounded feedback policy for Auto buffering on Android.
 *
 * It reacts to playback stalls and observed buffered media only. It does not
 * estimate bandwidth or choose a video rendition. One confirmed stall raises
 * the effective manual preset by one step, as do three short stalls within
 * 30 seconds; a long healthy window with a usable
 * cushion lowers it one step. The deepest choice is already byte-bounded by
 * [ExoBufferPolicy.MAX_PRESET_TARGET_BUFFER_BYTES].
 */
class AdaptiveBufferPolicy(initial: BufferPreset = BufferPreset.NORMAL) {
    companion object {
        const val STALL_PROMOTION_DELAY_MS = 1_000L
        const val SHORT_STALL_WINDOW_MS = 30_000L
        const val SHORT_STALL_COUNT = 3
        const val ADJUSTMENT_COOLDOWN_MS = 15_000L
        const val STABLE_PLAYBACK_BEFORE_REDUCTION_MS = 90_000L
        const val MINIMUM_HEALTHY_BUFFER_AHEAD_MS = 10_000L
    }

    var effectivePreset: BufferPreset = initial
        private set

    private val recentStalls = mutableListOf<Long>()
    private var started = false
    private var stallAdjusted = false
    private var stallSinceMs: Long? = null
    private var lastAdjustmentMs: Long? = null
    private var healthySinceMs: Long? = null

    /** Resets adaptation for a new channel. Reconnects should keep this state. */
    fun reset(initial: BufferPreset = BufferPreset.NORMAL) {
        effectivePreset = initial
        recentStalls.clear()
        started = false
        stallAdjusted = false
        stallSinceMs = null
        lastAdjustmentMs = null
        healthySinceMs = null
    }

    /** Clears elapsed observations while preserving the effective preset. */
    fun resetObservationWindow() {
        recentStalls.clear()
        started = false
        stallAdjusted = false
        stallSinceMs = null
        healthySinceMs = null
    }

    /** Returns a changed effective preset, or null when no adjustment is due. */
    fun observe(
        nowMs: Long,
        playing: Boolean,
        buffering: Boolean,
        ended: Boolean,
        bufferAheadMs: Long,
    ): BufferPreset? {
        if (ended) {
            recentStalls.clear()
            started = false
            stallAdjusted = false
            stallSinceMs = null
            healthySinceMs = null
            return null
        }

        if (!started) {
            if (playing && !buffering) {
                started = true
                if (bufferAheadMs >= MINIMUM_HEALTHY_BUFFER_AHEAD_MS) {
                    healthySinceMs = nowMs
                }
            }
            return null
        }

        if (buffering) {
            healthySinceMs = null
            recentStalls.removeAll { nowMs - it > SHORT_STALL_WINDOW_MS }
            if (stallSinceMs == null) {
                stallSinceMs = nowMs
                recentStalls.add(nowMs)
            }
            if (!stallAdjusted &&
                (nowMs - stallSinceMs!! >= STALL_PROMOTION_DELAY_MS ||
                    recentStalls.size >= SHORT_STALL_COUNT) &&
                cooldownElapsed(nowMs)
            ) {
                val promoted = stepUp()
                if (promoted != null) {
                    recentStalls.clear()
                    stallAdjusted = true
                    lastAdjustmentMs = nowMs
                    return promoted
                }
            }
            return null
        }

        stallSinceMs = null
        stallAdjusted = false
        if (!playing || bufferAheadMs < MINIMUM_HEALTHY_BUFFER_AHEAD_MS) {
            healthySinceMs = null
            return null
        }

        if (healthySinceMs == null) healthySinceMs = nowMs
        if (nowMs - healthySinceMs!! < STABLE_PLAYBACK_BEFORE_REDUCTION_MS ||
            !cooldownElapsed(nowMs)
        ) {
            return null
        }
        val reduced = stepDown() ?: return null
        healthySinceMs = nowMs
        lastAdjustmentMs = nowMs
        return reduced
    }

    private fun cooldownElapsed(nowMs: Long): Boolean =
        lastAdjustmentMs == null || nowMs - lastAdjustmentMs!! >= ADJUSTMENT_COOLDOWN_MS

    private fun stepUp(): BufferPreset? {
        val next = BufferPreset.entries.getOrNull(effectivePreset.ordinal + 1) ?: return null
        effectivePreset = next
        return next
    }

    private fun stepDown(): BufferPreset? {
        val next = BufferPreset.entries.getOrNull(effectivePreset.ordinal - 1) ?: return null
        effectivePreset = next
        return next
    }
}
