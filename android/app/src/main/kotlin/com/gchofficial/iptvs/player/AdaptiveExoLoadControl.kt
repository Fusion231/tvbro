package com.gchofficial.iptvs.player

import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.upstream.Allocator

/**
 * Runtime-adjustable duration gates backed by media3's normal allocator and
 * lifecycle. This lets Auto change the sustained cushion without rebuilding
 * the engine or touching its active track selection. Deep presets also raise
 * recovery gates to 3/4 seconds while preserving the base startup gates.
 */
@UnstableApi
class AdaptiveExoLoadControl(
    initialPreset: BufferPreset,
    adaptive: Boolean,
) : LoadControl {
    private val delegate = DefaultLoadControl.Builder()
        // The delegate supplies the same allocator and its memory-pressure
        // behavior; the gates below narrow this ceiling to the selected preset.
        .setBufferDurationsMs(
            ExoBufferPolicy.forPreset(BufferPreset.MAX).minBufferMs,
            ExoBufferPolicy.forPreset(BufferPreset.MAX).maxBufferMs,
            ExoBufferPolicy.forPreset(BufferPreset.NORMAL).forPlaybackMs,
            ExoBufferPolicy.forPreset(BufferPreset.NORMAL).afterRebufferMs,
        )
        .setTargetBufferBytes(C.LENGTH_UNSET)
        .setPrioritizeTimeOverSizeThresholds(true)
        .build()

    @Volatile
    private var preset = if (adaptive) BufferPreset.NORMAL else initialPreset

    @Volatile
    private var automatic = adaptive

    // Accessed only by the ExoPlayer playback thread.
    private var loading = true

    fun setAdaptiveBuffer(enabled: Boolean, basePreset: BufferPreset, reset: Boolean) {
        automatic = enabled
        if (reset) preset = if (enabled) BufferPreset.NORMAL else basePreset
    }

    fun setAdaptivePreset(next: BufferPreset): Boolean {
        if (!automatic || next == preset) return false
        preset = next
        return true
    }

    fun effectivePreset(): BufferPreset = preset

    override fun onPrepared(playerId: PlayerId) {
        delegate.onPrepared(playerId)
        loading = true
    }

    override fun onTracksSelected(
        parameters: LoadControl.Parameters,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) {
        delegate.onTracksSelected(parameters, trackGroups, trackSelections)
    }

    override fun onStopped(playerId: PlayerId) {
        delegate.onStopped(playerId)
        loading = false
    }

    override fun onReleased(playerId: PlayerId) {
        delegate.onReleased(playerId)
    }

    override fun getAllocator(playerId: PlayerId): Allocator =
        delegate.getAllocator(playerId)

    override fun getBackBufferDurationUs(playerId: PlayerId): Long =
        delegate.getBackBufferDurationUs(playerId)

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
        delegate.retainBackBufferFromKeyframe(playerId)

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        val delegateAllows = delegate.shouldContinueLoading(parameters)
        val policy = ExoBufferPolicy.forPreset(preset)
        val bufferedUs = parameters.bufferedDurationUs
        val minBufferUs = maxOf(500_000L, policy.minBufferMs * 1_000L)
        val maxBufferUs = policy.maxBufferMs * 1_000L
        val byteCapApplies = automatic || preset == BufferPreset.MAX
        val byteCapReached = byteCapApplies &&
            getAllocator(parameters.playerId).totalBytesAllocated >=
            ExoBufferPolicy.MAX_PRESET_TARGET_BUFFER_BYTES

        when {
            byteCapReached || bufferedUs >= maxBufferUs || !delegateAllows -> loading = false
            bufferedUs < minBufferUs -> loading = true
            // Between the low and high watermarks, keep the previous loading
            // state just like DefaultLoadControl's hysteresis.
        }
        return loading
    }

    private fun playbackThresholdMs(rebuffering: Boolean): Int {
        // A deeper recovery cushion must not delay a channel's first frame.
        if (!rebuffering) {
            return ExoBufferPolicy.forPreset(
                if (automatic) BufferPreset.NORMAL else preset,
            ).forPlaybackMs
        }
        return when (preset) {
            BufferPreset.HIGH -> 3_000
            BufferPreset.MAX -> 4_000
            else -> ExoBufferPolicy.forPreset(preset).afterRebufferMs
        }
    }

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean {
        var thresholdUs = playbackThresholdMs(parameters.rebuffering) * 1_000L
        if (parameters.targetLiveOffsetUs != C.TIME_UNSET) {
            thresholdUs = minOf(thresholdUs, parameters.targetLiveOffsetUs / 2)
        }
        val playoutBufferUs = if (parameters.playbackSpeed > 0f) {
            (parameters.bufferedDurationUs / parameters.playbackSpeed).toLong()
        } else {
            parameters.bufferedDurationUs
        }
        val byteCapApplies = automatic || preset == BufferPreset.MAX
        val byteCapReached = byteCapApplies &&
            getAllocator(parameters.playerId).totalBytesAllocated >=
            ExoBufferPolicy.MAX_PRESET_TARGET_BUFFER_BYTES
        return thresholdUs <= 0 || playoutBufferUs >= thresholdUs || byteCapReached
    }

    override fun shouldContinuePreloading(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDurationUs: Long,
    ): Boolean = delegate.shouldContinuePreloading(
        playerId,
        timeline,
        mediaPeriodId,
        bufferedDurationUs,
    )
}
