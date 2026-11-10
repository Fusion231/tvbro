package com.gchofficial.iptvs.player

import android.content.Context
import android.util.Log
import android.view.SurfaceHolder
import dev.jdtech.mpv.MPVLib
import java.util.Locale

/**
 * Wraps libmpv (gpu-next / libplacebo) for the native HDR player — the same engine
 * as the Windows path. Unlike ExoPlayer/MediaCodec, mpv can software-reshape Dolby
 * Vision Profile 5 (single-layer, no HDR10 base) and tone-map to the display, so
 * DV titles render on non-DV hardware (e.g. Samsung Galaxy).
 *
 * Owns the MPVLib instance, mirrors mpv property changes into [PlayerUiState] (on
 * the main thread via [post]), and exposes the playback actions the Compose overlay
 * invokes through [PlayerCallbacks].
 */
class MpvController(
    private val context: Context,
    private val state: PlayerUiState,
    private val post: (() -> Unit) -> Unit,
    /** `cache-secs` for this session, or null for mpv's own default. */
    private val cacheSecs: Int? = null,
    hardwareDecoding: Boolean = false,
    private val onHdrChanged: (Boolean) -> Unit = {},
) : MPVLib.EventObserver, SurfaceHolder.Callback {

    private var mpv: MPVLib? = null
    private val decodePolicy = MpvLoadDecodePolicy(hardwareDecoding)
    private var pendingSubtitles: List<SubtitleSpec> = emptyList()
    private var defaultCacheSecs: String? = null

    fun create(headers: Map<String, String>) {
        val instance = MPVLib.create(context) ?: run {
            Log.e(TAG, "MPVLib.create returned null")
            return
        }
        mpv = instance
        with(instance) {
            // Per-source buffering, when the user moved off the default.
            // Set with the other options so it is in effect for the first
            // load rather than applied to an already-running demuxer.
            cacheSecs?.let { setOptionString("cache-secs", it.toString()) }
            setOptionString("config", "no")
            setOptionString("idle", "yes")
            setOptionString("force-window", "no")
            setOptionString("vo", "gpu-next")
            setOptionString("gpu-context", "android")
            // Keep software decoding for Dolby Vision/unknown tracks. For known
            // non-DV video, MediaCodec copies decoded frames to the same renderer;
            // mpv still falls back to software if hardware decoding fails.
            setOptionString("hwdec", "no")
            setOptionString("vid", "auto")
            // HDR / Dolby Vision: libplacebo reshapes DV, then tone-maps HDR→SDR for
            // the display. We deliberately do NOT set target-colorspace-hint: a custom
            // Android SurfaceView doesn't reliably switch the panel into true HDR, and
            // with the hint on mpv passes PQ through unchanged → a dark picture. A
            // high-quality tone-map looks correct and bright instead.
            setOptionString("tone-mapping", "auto")
            setOptionString("hdr-compute-peak", "yes")
            setOptionString("gamut-mapping-mode", "perceptual")
            // Housekeeping: never read user config, never touch yt-dlp, keep quiet.
            // Silence libav's non-fatal decode/demux chatter (alternating
            // `hevc: Could not find ref with POC …` etc. from poorly-muxed DV P5)
            // at the source so it doesn't flood the shared av_log callback that
            // media_kit relays into the Dart diagnostics log.
            setOptionString("msg-level", "ffmpeg=fatal")
            setOptionString("ytdl", "no")
            setOptionString("save-position-on-quit", "no")
            setOptionString("sub-auto", "no")
            // Network resiliency for live streams: bound stalls and let ffmpeg
            // transparently reconnect transient HTTP drops (the host watchdog
            // reloads if a stall outlasts this). See [MpvLiveOptions] for why
            // `reconnect_at_eof` must stay out of `stream-lavf-o`.
            setOptionString("network-timeout", MpvLiveOptions.NETWORK_TIMEOUT)
            setOptionString("stream-lavf-o", MpvLiveOptions.STREAM_LAVF_O)
            applyHeaders(this, headers)
            init()
        }
        defaultCacheSecs = runCatching {
            instance.getPropertyString("option-info/cache-secs/default-value")
        }.getOrNull()
        instance.addObserver(this)
        observeProperties(instance)
    }

    /** Applies an effective cache depth without reopening the current stream. */
    fun setAdaptiveBufferPreset(preset: BufferPreset): Boolean {
        val instance = mpv ?: return false
        val value = preset.mpvCacheSecs?.toString() ?: defaultCacheSecs
        if (value == null) {
            Log.w(TAG, "adaptive buffer could not restore mpv's default cache depth")
            return false
        }
        return runCatching {
            instance.setPropertyString("cache-secs", value)
            true
        }.getOrElse {
            Log.w(TAG, "adaptive buffer cache depth could not be applied", it)
            false
        }
    }

    private fun applyHeaders(mpv: MPVLib, headers: Map<String, String>) {
        if (headers.isEmpty()) return
        headers.entries.firstOrNull { it.key.equals("user-agent", true) }?.let {
            mpv.setOptionString("user-agent", it.value)
        }
        headers.entries.firstOrNull {
            it.key.equals("referer", true) || it.key.equals("referrer", true)
        }?.let { mpv.setOptionString("referrer", it.value) }
        val rest = headers.entries.filter {
            !it.key.equals("user-agent", true) &&
                !it.key.equals("referer", true) &&
                !it.key.equals("referrer", true)
        }
        if (rest.isNotEmpty()) {
            mpv.setOptionString(
                "http-header-fields",
                MpvOptionEncoding.encodeHeaderFields(rest.map { it.key to it.value }),
            )
        }
    }

    private fun observeProperties(mpv: MPVLib) {
        mpv.observeProperty("time-pos", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("duration", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("demuxer-cache-time", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("pause", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("paused-for-cache", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("seeking", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("eof-reached", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("volume", MPVLib.MpvFormat.MPV_FORMAT_INT64)
        mpv.observeProperty("mute", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("speed", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("track-list/count", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    }

    fun load(url: String, subtitles: List<SubtitleSpec>) {
        // A reused engine may receive a different channel or local DVR stream.
        // Only the first load has the Exo format evidence passed at creation.
        mpv?.setPropertyString("hwdec", decodePolicy.nextHwdec())
        pendingSubtitles = subtitles
        state.loadingStream = true
        state.isSeeking = false
        state.isBuffering = true
        state.ended = false
        state.playbackRequested = true
        // Choose the replay cursor before FFmpeg opens HLS; an immediate seek
        // after loadfile can arrive before the file is ready and lose the seek.
        mpv?.setPropertyString(
            "demuxer-lavf-o",
            if (state.dvrActive) "live_start_index=0,prefer_x_start=1" else "",
        )
        mpv?.setPropertyString("start", if (state.dvrActive) "0" else "none")
        mpv?.command(arrayOf("loadfile", url))
        // A reload while paused (go-to-live) must resume; loadfile keeps the
        // current pause state otherwise.
        mpv?.setPropertyBoolean("pause", false)
    }

    // ---- Playback actions (invoked from the Compose overlay) ----------------

    fun playPause() = mpv?.command(arrayOf("cycle", "pause")) ?: Unit
    fun seekBy(deltaMs: Long) =
        mpv?.command(arrayOf("seek", (deltaMs / 1000.0).toString(), "relative")) ?: Unit
    fun seekTo(positionMs: Long) =
        mpv?.command(arrayOf("seek", (positionMs / 1000.0).toString(), "absolute")) ?: Unit
    fun setVolume(value: Float) {
        mpv?.setPropertyInt("volume", (value.coerceIn(0f, 1f) * 100).toInt())
    }
    fun toggleMute() = mpv?.command(arrayOf("cycle", "mute")) ?: Unit
    fun setSpeed(value: Float) = mpv?.setPropertyDouble("speed", value.toDouble()) ?: Unit

    fun selectAudio(id: String) {
        id.toIntOrNull()?.let { mpv?.setPropertyInt("aid", it) }
    }

    fun selectSubtitle(id: String) {
        if (id == SUBTITLE_OFF_ID) {
            mpv?.setPropertyString("sid", "no")
        } else {
            id.toIntOrNull()?.let { mpv?.setPropertyInt("sid", it) }
        }
    }

    /** Applies the aspect/zoom mode — mirrors the Windows `_cycleNativeAspect` mapping. */
    fun applyAspect(mode: AspectMode) {
        val mpv = mpv ?: return
        when (mode) {
            AspectMode.Fit -> {
                // Every branch restores `keepaspect` explicitly rather than
                // assuming it: the modes are cycled, so leaving Stretch must
                // undo it on the very next press.
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "-1")
            }
            AspectMode.Fill -> {
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("video-aspect-override", "-1")
                mpv.setPropertyString("panscan", "1.0")
            }
            // `keepaspect=no` is mpv's stretch: the picture is scaled to the
            // window on both axes independently. Distinct from `panscan`, which
            // crops to fill while preserving the shape.
            AspectMode.Stretch -> {
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "-1")
                mpv.setPropertyString("keepaspect", "no")
            }
            AspectMode.Ratio16x9 -> {
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "16:9")
            }
            AspectMode.Ratio4x3 -> {
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "4:3")
            }
        }
    }

    // ---- Surface lifecycle --------------------------------------------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        mpv?.attachSurface(holder.surface)
        // Let mpv create its renderer now that there's a surface to draw into.
        mpv?.setOptionString("force-window", "yes")
        mpv?.setPropertyString("vo", "gpu-next")
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        mpv?.setPropertyString("android-surface-size", "${width}x$height")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        mpv?.setPropertyString("vo", "null")
        mpv?.setOptionString("force-window", "no")
        mpv?.detachSurface()
    }

    fun pause() = mpv?.setPropertyBoolean("pause", true) ?: Unit
    fun stop() {
        mpv?.command(arrayOf("stop"))
        state.loadingStream = false
        state.isSeeking = false
        state.isBuffering = false
        state.playbackRequested = false
    }

    fun destroy() {
        val instance = mpv ?: return
        mpv = null
        runCatching {
            instance.removeObserver(this)
            instance.command(arrayOf("stop"))
            instance.detachSurface()
            instance.destroy()
        }
    }

    // ---- Property/event observation (mpv thread → main thread) ---------------

    override fun eventProperty(property: String) {}

    override fun eventProperty(property: String, value: Long) = post {
        when (property) {
            "volume" -> {
                state.volume = (value / 100f).coerceIn(0f, 1f)
            }
            "track-list/count" -> refreshTracks()
        }
    }

    override fun eventProperty(property: String, value: Double) = post {
        when (property) {
            "time-pos" -> state.positionMs = (value * 1000).toLong().coerceAtLeast(0)
            "duration" -> state.durationMs = (value * 1000).toLong().coerceAtLeast(0)
            "demuxer-cache-time" -> if (value >= 0) {
                state.bufferedMs = (value * 1000).toLong()
            }
            "speed" -> state.speed = value.toFloat()
        }
    }

    override fun eventProperty(property: String, value: Boolean) = post {
        when (property) {
            "pause" -> {
                state.isPlaying = !value
                state.playbackRequested = !value
            }
            "paused-for-cache" -> state.isBuffering = value
            "seeking" -> state.isSeeking = value
            "eof-reached" -> state.ended = value
            "mute" -> state.muted = value
        }
    }

    override fun eventProperty(property: String, value: String) {}

    override fun event(eventId: Int) {
        when (eventId) {
            MPVLib.MpvEvent.MPV_EVENT_START_FILE -> post {
                state.loadingStream = true
                state.isSeeking = false
                state.isBuffering = true
                state.ended = false
            }
            MPVLib.MpvEvent.MPV_EVENT_FILE_LOADED -> post {
                addPendingSubtitles()
                refreshMediaInfo()
                refreshTracks()
            }
            MPVLib.MpvEvent.MPV_EVENT_VIDEO_RECONFIG,
            MPVLib.MpvEvent.MPV_EVENT_AUDIO_RECONFIG,
            -> post { refreshMediaInfo() }
            MPVLib.MpvEvent.MPV_EVENT_PLAYBACK_RESTART -> post {
                state.loadingStream = false
                state.isSeeking = false
                state.isBuffering = false
            }
            MPVLib.MpvEvent.MPV_EVENT_END_FILE -> post {
                state.ended = true
                state.loadingStream = false
                state.isSeeking = false
                state.isBuffering = false
            }
        }
    }

    private fun addPendingSubtitles() {
        val mpv = mpv ?: return
        for (sub in pendingSubtitles) {
            if (sub.url.isBlank()) continue
            mpv.command(arrayOf("sub-add", sub.url, "auto", sub.label, sub.language))
        }
        pendingSubtitles = emptyList()
    }

    private fun refreshMediaInfo() {
        val mpv = mpv ?: return
        (mpv.getPropertyInt("dwidth") ?: mpv.getPropertyInt("width"))?.let {
            if (it > 0) state.videoWidth = it
        }
        (mpv.getPropertyInt("dheight") ?: mpv.getPropertyInt("height"))?.let {
            if (it > 0) state.videoHeight = it
        }
        (mpv.getPropertyDouble("container-fps")
            ?: mpv.getPropertyDouble("estimated-vf-fps"))?.let {
            if (it > 0) state.fps = it.toFloat()
        }
        mpv.getPropertyString("video-format")?.let { state.videoCodec = codecLabel(it) }
        mpv.getPropertyString("audio-codec-name")?.let { state.audioCodec = codecLabel(it) }
        mpv.getPropertyInt("audio-params/channel-count")?.let { state.audioChannels = it }
        val range = dynamicRangeLabel(mpv)
        state.dynamicRange = range
        onHdrChanged(range.isHdr())
    }

    private fun String.isHdr(): Boolean =
        contains("HDR") || contains("Dolby", ignoreCase = true) || contains("HLG")

    private fun dynamicRangeLabel(mpv: MPVLib): String {
        val gamma = mpv.getPropertyString("video-params/gamma").orEmpty().lowercase(Locale.ROOT)
        val matrix = mpv.getPropertyString("video-params/colormatrix").orEmpty().lowercase(Locale.ROOT)
        val primaries = mpv.getPropertyString("video-params/primaries").orEmpty().lowercase(Locale.ROOT)
        return when {
            matrix.contains("dolby") || gamma.contains("dolby") -> "Dolby Vision"
            gamma == "pq" -> "HDR10 · PQ"
            gamma == "hlg" -> "HLG"
            primaries.contains("2020") -> "HDR · BT.2020"
            gamma.isNotEmpty() -> "SDR"
            else -> ""
        }
    }

    private var qualityPreference = "auto"

    fun videoQualities(): List<Map<String, Any>> {
        val mpv = mpv ?: return emptyList()
        val count = mpv.getPropertyInt("track-list/count") ?: return emptyList()
        return (0 until count).mapNotNull { index ->
            if (mpv.getPropertyString("track-list/$index/type") != "video") return@mapNotNull null
            val id = mpv.getPropertyInt("track-list/$index/id") ?: return@mapNotNull null
            val height = mpv.getPropertyInt("track-list/$index/demux-h") ?: 0
            if (height <= 0) return@mapNotNull null
            mapOf("id" to id.toString(), "height" to height,
                "bitrate" to (mpv.getPropertyInt("track-list/$index/demux-bitrate") ?: 0))
        }
    }

    fun selectQuality(key: String) {
        qualityPreference = key
        val mpv = mpv ?: return
        if (key == "auto") { mpv.setPropertyString("vid", "auto"); return }
        val height = key.substringBefore(':').toIntOrNull() ?: return
        val choices = videoQualities().sortedWith(
            compareBy<Map<String, Any>> { it["height"] as Int }
                .thenBy { it["bitrate"] as Int },
        )
        val chosen = choices.firstOrNull { "${it["height"]}:${it["bitrate"]}" == key }
            ?: choices.lastOrNull { (it["height"] as Int) <= height }
            ?: choices.firstOrNull() ?: return
        val id = chosen["id"] as String
        if (mpv.getPropertyString("vid") != id) mpv.setPropertyString("vid", id)
    }

    private fun refreshTracks() {
        val mpv = mpv ?: return
        val count = mpv.getPropertyInt("track-list/count") ?: return
        val currentAid = mpv.getPropertyInt("aid")
        val currentSid = mpv.getPropertyInt("sid")

        val audio = mutableListOf<TrackOption>()
        val subs = mutableListOf(TrackOption(SUBTITLE_OFF_ID, playerText("Off")))

        for (i in 0 until count) {
            val type = mpv.getPropertyString("track-list/$i/type") ?: continue
            val id = mpv.getPropertyInt("track-list/$i/id") ?: continue
            val title = mpv.getPropertyString("track-list/$i/title")
            val lang = mpv.getPropertyString("track-list/$i/lang")
            when (type) {
                "audio" -> audio.add(TrackOption(id.toString(), trackLabel(title, lang, "Audio", audio.size)))
                "sub" -> subs.add(TrackOption(id.toString(), trackLabel(title, lang, "Subtitle", subs.size - 1)))
            }
        }

        state.audioTracks = audio
        state.selectedAudioId = currentAid?.toString() ?: audio.firstOrNull()?.id
        state.subtitleTracks = subs
        state.selectedSubtitleId = currentSid?.toString() ?: SUBTITLE_OFF_ID
        selectQuality(qualityPreference)
    }

    private fun trackLabel(title: String?, lang: String?, fallback: String, index: Int): String {
        title?.takeIf { it.isNotBlank() }?.let { return it }
        languageLabel(lang)?.let { return it }
        return "${playerText(fallback)} ${index + 1}"
    }

    private fun languageLabel(lang: String?): String? {
        val code = lang?.takeIf { it.isNotBlank() && it != "und" } ?: return null
        return runCatching {
            Locale.forLanguageTag(code).getDisplayName(PlayerStrings.locale).takeIf { it.isNotBlank() }
        }.getOrNull() ?: code
    }

    private fun codecLabel(format: String): String = when (format.lowercase(Locale.ROOT)) {
        "hevc", "h265" -> "HEVC"
        "h264", "avc" -> "H.264"
        "av1" -> "AV1"
        "vp9" -> "VP9"
        "mpeg2video" -> "MPEG-2"
        "aac" -> "AAC"
        "ac3" -> "AC-3"
        "eac3" -> "E-AC-3"
        "truehd" -> "TrueHD"
        "dts" -> "DTS"
        "flac" -> "FLAC"
        "opus" -> "Opus"
        "mp3" -> "MP3"
        else -> format.uppercase(Locale.ROOT)
    }

    companion object {
        private const val TAG = "iptvs.mpv"
    }
}
