package com.gchofficial.iptvs.player

/** Completion observer for HTTP sources, including asynchronous Loader cancellation. */
class ProviderConnectionTracker {
    private var active = 0
    private val listeners = mutableListOf<() -> Unit>()
    @Synchronized fun opened() { active++ }
    fun closed() {
        val callbacks = synchronized(this) {
            check(active > 0)
            active--
            if (active == 0) listeners.toList().also { listeners.clear() } else emptyList()
        }
        callbacks.forEach { it() }
    }
    fun whenIdle(onIdle: () -> Unit) {
        val idle = synchronized(this) {
            if (active == 0) true else { listeners.add(onIdle); false }
        }
        if (idle) onIdle()
    }
}
