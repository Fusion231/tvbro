package com.gchofficial.iptvs.player

/** Infer a source rate only from a continuous run without decoder frame drops. */
class ContentFrameRateSampler {
    private val intervalsUs = mutableListOf<Long>()
    private var lastPresentationUs = Long.MIN_VALUE
    private var lastDroppedFrames = -1

    fun reset() {
        intervalsUs.clear()
        lastPresentationUs = Long.MIN_VALUE
        lastDroppedFrames = -1
    }

    fun sample(presentationUs: Long, droppedFrames: Int): Float? {
        val previous = lastPresentationUs
        lastPresentationUs = presentationUs
        val dropsChanged = droppedFrames != lastDroppedFrames
        lastDroppedFrames = droppedFrames
        // Rendered timestamps omit dropped frames: a struggling 50fps decoder
        // can otherwise look like a 25fps source and lock that rate indefinitely.
        if (previous == Long.MIN_VALUE || droppedFrames < 0 || dropsChanged) {
            intervalsUs.clear()
            return null
        }
        val interval = presentationUs - previous
        if (interval <= 0L || interval > 200_000L) {
            intervalsUs.clear()
            return null
        }
        intervalsUs.add(interval)
        if (intervalsUs.size < 30) return null
        val median = intervalsUs.sorted()[intervalsUs.size / 2]
        intervalsUs.clear()
        return 1_000_000f / median
    }
}
