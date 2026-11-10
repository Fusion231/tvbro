package com.gchofficial.iptvs.player

/** Input rules shared by the video gestures and the native control callbacks. */
object PlayerInputPolicy {
    // Android's volume keys belong to the OS even when the player chrome is hidden.
    fun isSystemVolumeKey(keyCode: Int): Boolean =
        keyCode == 24 || keyCode == 25 || keyCode == 164

    fun seekTarget(positionMs: Long, durationMs: Long, deltaMs: Long): Long {
        val target = (positionMs.coerceAtLeast(0L) + deltaMs).coerceAtLeast(0L)
        return if (durationMs > 0L) target.coerceAtMost(durationMs) else target
    }
}
