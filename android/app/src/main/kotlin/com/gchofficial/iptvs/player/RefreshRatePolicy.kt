package com.gchofficial.iptvs.player

import kotlin.math.abs
import kotlin.math.round

/** Prefer an exact multiple without changing resolution or accepting 24 -> 25. */
fun matchingRefreshRate(fps: Float, rates: List<Float>, current: Float): Float? {
    if (!fps.isFinite() || fps < 10f || fps > 240f) return null
    fun matches(rate: Float): Boolean {
        if (!rate.isFinite() || rate < fps - 0.1f) return false
        val multiple = round(rate / fps)
        return multiple >= 1 && abs(rate - fps * multiple) <= 0.15f
    }
    if (matches(current)) return current
    return rates.filter(::matches).minOrNull()
}
