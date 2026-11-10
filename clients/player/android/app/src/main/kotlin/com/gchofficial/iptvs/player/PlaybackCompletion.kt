package com.gchofficial.iptvs.player

/** A load may complete once; stop, replacement and errors are never media EOF. */
class PlaybackCompletion {
    private var loaded = false
    private var reported = false

    fun beginLoad() { loaded = true; reported = false }
    fun stop() { loaded = false }
    fun seekBeforeEnd() { if (loaded) reported = false }
    fun seekToEnd() { if (loaded) reported = true }
    fun ended(isNaturalEnd: Boolean): Boolean {
        if (!loaded || reported || !isNaturalEnd) return false
        reported = true
        return true
    }
}
