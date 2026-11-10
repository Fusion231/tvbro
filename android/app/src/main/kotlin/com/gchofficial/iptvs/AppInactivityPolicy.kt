package com.gchofficial.iptvs

/** One app session spans Flutter, native fullscreen and visible picture-in-picture. */
internal class AppInactivityPolicy(initial: Snapshot = Snapshot()) {
    data class Snapshot(
        val backgroundAtMs: Long? = null,
        val bootCount: Int = -1,
        val resetPending: Boolean = false,
        val generation: Long = 0L,
    )

    var snapshot = initial
        private set
    private val started = mutableSetOf<Any>()
    private val pictureInPicture = mutableSetOf<Any>()
    private val visible: Boolean get() = started.isNotEmpty() || pictureInPicture.isNotEmpty()

    fun activityStarted(owner: Any, nowMs: Long, bootCount: Int) {
        checkExpiry(nowMs, bootCount)
        started.add(owner)
        snapshot = snapshot.copy(backgroundAtMs = null)
    }

    fun activityStopped(owner: Any, nowMs: Long, bootCount: Int, changingConfiguration: Boolean) {
        started.remove(owner)
        markBackground(nowMs, bootCount, changingConfiguration)
    }

    fun pictureInPictureChanged(owner: Any, shown: Boolean, nowMs: Long, bootCount: Int) {
        if (shown) {
            pictureInPicture.add(owner)
            snapshot = snapshot.copy(backgroundAtMs = null)
        } else {
            pictureInPicture.remove(owner)
            markBackground(nowMs, bootCount)
        }
    }

    fun activityDestroyed(owner: Any, nowMs: Long, bootCount: Int, changingConfiguration: Boolean) {
        started.remove(owner)
        pictureInPicture.remove(owner)
        markBackground(nowMs, bootCount, changingConfiguration)
    }

    private fun markBackground(nowMs: Long, bootCount: Int, changingConfiguration: Boolean = false) {
        if (!visible && !changingConfiguration && snapshot.backgroundAtMs == null) {
            snapshot = snapshot.copy(backgroundAtMs = nowMs, bootCount = bootCount)
        }
    }

    fun checkExpiry(nowMs: Long, bootCount: Int): Boolean {
        val since = snapshot.backgroundAtMs
        if (!visible && since != null &&
            (snapshot.bootCount != bootCount || nowMs < since || nowMs - since >= TIMEOUT_MS)
        ) {
            snapshot = snapshot.copy(
                backgroundAtMs = null,
                resetPending = true,
                generation = snapshot.generation + 1L,
            )
        }
        return snapshot.resetPending
    }

    fun consumeReset(): Boolean {
        val pending = snapshot.resetPending
        snapshot = snapshot.copy(resetPending = false)
        return pending
    }

    companion object {
        const val TIMEOUT_MS = 10 * 60 * 1_000L
    }
}
