package com.gchofficial.iptvs

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.AspectMode
import com.gchofficial.iptvs.player.isTelevisionDevice
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.BufferPreset
import com.gchofficial.iptvs.player.AdaptiveBufferPolicy
import com.gchofficial.iptvs.player.RefreshRateMatcher
import com.gchofficial.iptvs.player.TrackOption
import com.gchofficial.iptvs.player.ExoPlayerEngine
import com.gchofficial.iptvs.player.FrameLivenessWatch
import com.gchofficial.iptvs.player.LiveLocator
import com.gchofficial.iptvs.player.MpvEngine
import com.gchofficial.iptvs.player.PlaybackEngine
import com.gchofficial.iptvs.player.PlaybackStatsSampler
import com.gchofficial.iptvs.player.PlayerCallbacks
import com.gchofficial.iptvs.player.PlayerInputPolicy
import com.gchofficial.iptvs.player.PlayerBackAction
import com.gchofficial.iptvs.player.PlayerBackGuard
import com.gchofficial.iptvs.player.PlayerStrings
import com.gchofficial.iptvs.player.PlayerMenu
import com.gchofficial.iptvs.player.PlayerScreen
import com.gchofficial.iptvs.player.PlayerUiState
import com.gchofficial.iptvs.player.QuickListState
import com.gchofficial.iptvs.player.ReconnectPolicy
import com.gchofficial.iptvs.player.ResolveAgainReply
import com.gchofficial.iptvs.player.ResolveGate
import com.gchofficial.iptvs.player.SharedEngine
import com.gchofficial.iptvs.player.SubtitleSpec
import com.gchofficial.iptvs.player.ZapKeyPolicy
import com.gchofficial.iptvs.player.ZapKeyAction
import com.gchofficial.iptvs.player.nextPlayerBackAction
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import org.json.JSONArray

/**
 * Native HDR player. Hosts a [PlaybackEngine] behind the Jetpack Compose control
 * overlay ([PlayerScreen]). Starts on [ExoPlayerEngine] (MediaCodec hardware decode
 * → true HDR); if ExoPlayer can't decode the video track (e.g. Dolby Vision
 * Profile 5 on non-DV hardware) it falls back once to [MpvEngine] (libmpv, which
 * software-reshapes DV and tone-maps). The engine swap is device-aware: on
 * DV-capable hardware ExoPlayer handles everything and the fallback never fires.
 */
@UnstableApi
class HdrPlayerActivity : ComponentActivity() {
    private lateinit var uiState: PlayerUiState
    private lateinit var url: String
    private lateinit var headers: Map<String, String>
    private lateinit var subtitles: List<SubtitleSpec>

    private val engineState = mutableStateOf<PlaybackEngine?>(null)
    private var engine: PlaybackEngine? = null
    private var progressTicker: Job? = null
    private var dvrPlaybackId = 0L
    private var dvrSuspended = false
    private var selectedEpisodeId: String? = null

    // Debug-only: lets an integration-test soak cycle this Activity without a
    // human closing it each time. Inert (never scheduled) outside BuildConfig.DEBUG.
    private var soakAutoCloseJob: Job? = null

    // True while this Activity plays through the *adopted* shared preview engine
    // (see [SharedEngine]): it never releases that engine — on exit it hands the
    // video output back to the preview instead.
    private var adoptedShared = false

    // Live reconnect watchdog: when a live stream stalls (buffering) or drops
    // (ended / error), reload it with capped backoff until playback resumes.
    private var stalledSinceMs = 0L
    private var lastReconnectMs = 0L
    private var reconnectAttempt = 0

    // The third stall shape, and the one that used to be invisible: playing
    // normally by every flag the engine exposes, with nothing reaching the
    // screen. See [FrameLivenessWatch].
    private val frameLiveness = FrameLivenessWatch()

    // Cheap recoveries spent on this session's handoff. One is the budget: if a
    // fresh decoder on the same surface still draws nothing, the surface switch
    // wasn't the problem and the reload watchdog owns it from there.
    private var handoffRebuilds = 0

    // Why the current reconnect fired, for the diagnostics line. Set at the
    // point of decision so the log distinguishes an underrun from a drop from
    // a frozen renderer, which otherwise all read as "reconnect attempt=1".
    private var stallKind = "none"

    // Wall clock for this Activity's own timeline: every diagnostic it emits is
    // stamped with ms since onCreate, so a report shows where in the handoff the
    // time went instead of only that it went.
    private var startedAtMs = 0L

    // Live re-resolve round trip (see [withFreshLiveLocator]). The gate keeps
    // the watchdog and "Go to live" to one in-flight `create_link` between them
    // and settles the reply-vs-timeout race exactly once.
    private val resolveGate = ResolveGate()
    private var resolveTimeoutJob: Job? = null

    // The user's manual ceiling and Auto's live effective level are kept
    // separately so channel zaps can reset adaptation without losing the
    // saved manual choice.
    private var bufferPreset: BufferPreset = BufferPreset.NORMAL
    private var adaptiveBuffer = false
    private val adaptiveBufferPolicy = AdaptiveBufferPolicy()
    private var settingsSession = 0
    private var qualityPreference = "auto"
    private var matchRefreshRate = false
    private val refreshRateMatcher by lazy { RefreshRateMatcher(this) }

    // Live zapping (Dart owns the channel list and the cursor — see
    // `lib/player/live_zap_controller.dart`). The Activity holds only what a
    // *synchronous* key decision needs.
    //
    // `zapConsumedKeyCode` pairs a consumed ACTION_UP with the ACTION_DOWN
    // that claimed it: the state the policy reads (a half-typed number) can
    // change between the two, and a bare key-up reaching a focused Compose
    // control would activate it right after the down had already been used
    // for something else.
    private var zapConsumedKeyCode: Int? = null

    // Optimistic mirror of "a channel number is half-typed".
    //
    // The authoritative buffer is Dart's and arrives back on `setZapBanner`,
    // but that is a frame or two away, and OK or Back pressed inside that
    // window would otherwise fall through to the overlay — on a remote, a
    // fast "1 OK" is the normal way to enter a single-digit channel. Set when
    // a digit is dispatched and replaced wholesale by the next authoritative
    // push, so it can only ever be early, never stale.
    private var zapDigitsPendingOptimistic = false

    // Optimistic mirror of "the quick list is on screen", the same shape and
    // for the same synchronous reason as the digit mirror above: the
    // authoritative answer arrives on `setQuickList` a frame or two after the
    // key that asked for it, and the *next* key's meaning turns on it (Left
    // opens the list, then Left ascends its mode stack). Only the two
    // unambiguous commands move it — open and close. `zap:back` and
    // `zap:activate` deliberately do not, because whether either of those
    // closes the list is a question about a mode stack only Dart holds.
    // Replaced wholesale by the next push, so it can only ever be early.
    private var zapQuickListOpenOptimistic = false

    // When Dart last reported a zap resolve in flight (`setZapBanner`'s
    // `settling`). While one is, the reconnect watchdog stands down: the
    // stream it would be reconnecting is one Dart is deliberately replacing.
    // Bounded by ResolveGate.TIMEOUT_MS so a banner whose follow-up never
    // arrives cannot wedge the watchdog for the rest of the session.
    private var zapSettlingSinceMs = 0L
    private val backGuard = PlayerBackGuard()
    // Entering PiP moves MainActivity's task behind the launcher so the pinned
    // window is unobstructed.  When the restored player is then closed, the
    // player task would otherwise finish into the launcher instead of the
    // Flutter streams route.  Remember that this Activity has used PiP so its
    // finish path can restore the existing MainActivity task first.
    private var enteredPip = false

    /**
     * TV remotes and three-button navigation arrive as key events. Consume both
     * key-down and key-up at the Activity boundary so Compose focus handlers and
     * the Back dispatcher cannot process the same physical press again.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (dispatchZapKey(event)) return true
        // Record is an explicit command, so execute it before Compose's
        // hidden-controls handler consumes the first key only to wake chrome.
        if (event.keyCode == KeyEvent.KEYCODE_MEDIA_RECORD &&
            ::uiState.isInitialized && uiState.dvrAvailable
        ) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                if (!quickListOpen()) uiState.controlsVisible = true
                sendDvr("record")
            }
            return true
        }
        if (event.keyCode != KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            handleSystemBack()
        }
        return true
    }

    /**
     * Live zapping's share of the key stream, decided by the pure
     * [ZapKeyPolicy] at this same Activity boundary Back already uses — one
     * physical press must not be read once here and again by a focused
     * Compose control.
     *
     * Returns whether the press was consumed. Only the key-down sends a
     * command; its key-up is consumed by code so nothing downstream ever sees
     * half a press.
     */
    private fun dispatchZapKey(event: KeyEvent): Boolean {
        if (!::uiState.isInitialized) return false
        if (event.action == KeyEvent.ACTION_UP) {
            if (zapConsumedKeyCode != event.keyCode) return false
            zapConsumedKeyCode = null
            return true
        }
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val decision = ZapKeyPolicy.decide(
            keyCode = event.keyCode,
            isLive = uiState.isLive,
            controlsVisible = uiState.controlsVisible,
            digitsPending = uiState.digitBuffer.isNotEmpty() || zapDigitsPendingOptimistic,
            isRepeat = event.repeatCount > 0,
            quickListOpen = quickListOpen(),
        )
        if (!decision.consumed) return false
        zapConsumedKeyCode = event.keyCode
        // A digit keeps the banner up while the number is being typed; the
        // authoritative buffer still comes back from Dart on `setZapBanner`,
        // which is what the next key decision reads.
        if (decision.action == ZapKeyAction.Digit) {
            zapDigitsPendingOptimistic = true
            uiState.zapBannerVisible = true
        } else if (decision.action == ZapKeyAction.Activate ||
            decision.action == ZapKeyAction.Back
        ) {
            zapDigitsPendingOptimistic = false
        }
        if (decision.action == ZapKeyAction.OpenList) {
            zapQuickListOpenOptimistic = true
        } else if (decision.action == ZapKeyAction.CloseList) {
            zapQuickListOpenOptimistic = false
        }
        decision.command?.let { sendZap(it) }
        return true
    }

    /**
     * Whether the quick list should be treated as open *right now* — Dart's
     * last push, or the optimistic mirror while its answer is in the air.
     */
    private fun quickListOpen(): Boolean =
        (::uiState.isInitialized && uiState.quickList.open) || zapQuickListOpenOptimistic

    /** Outbound half of the zap wire contract (see `MainActivity.requestZap`). */
    private fun sendZap(command: String) {
        MainActivity.instance?.get()?.requestZap(command)
    }

    /** One press closes one layer: menu, info, controls, then Activity. */
    private fun handleSystemBack() {
        if (!backGuard.shouldHandle(SystemClock.elapsedRealtime())) return
        if (!::uiState.isInitialized) {
            finish()
            return
        }
        if (uiState.episodesOpen) {
            uiState.episodesOpen = false
            return
        }
        when (
            nextPlayerBackAction(
                menuOpen = uiState.openMenu != PlayerMenu.None,
                infoOpen = uiState.infoOpen,
                controlsVisible = uiState.controlsVisible,
                quickListOpen = quickListOpen(),
            )
        ) {
            // The list's rungs are Dart's mode stack, not a layer this side
            // can close. Only the *gesture* Back path reaches this: a key Back
            // was already claimed by ZapKeyPolicy and sent the same command,
            // which is why one press can never peel two rungs.
            PlayerBackAction.QuickListBack -> sendZap("zap:back")
            PlayerBackAction.CloseMenu -> uiState.openMenu = PlayerMenu.None
            PlayerBackAction.CloseInfo -> uiState.infoOpen = false
            PlayerBackAction.HideControls -> uiState.controlsVisible = false
            PlayerBackAction.Exit -> finish()
        }
    }

    private val playbackStats = PlaybackStatsSampler()

    /**
     * Periodic frame-rate/drop line while playing.
     *
     * Rides the existing ticker rather than adding a timer, and only while the
     * engine says it is playing: a paused or buffering player renders nothing,
     * and reporting 0fps for it would bury the case this exists to catch.
     */
    private fun samplePlaybackStats() {
        if (!uiState.isPlaying || uiState.isBuffering) {
            // Drop the baseline rather than just skipping. The rate is
            // frames-over-wall-clock, so carrying a baseline across a pause, a
            // rebuffer or a trip through onStop/onStart would divide the frames
            // by the *idle* time too: a 60s pause reports `fps=3.8 dropped=+0`
            // on resume — which is precisely the "low rate, no drops" signature
            // this exists to detect. A diagnostic that manufactures its own
            // headline symptom is worse than none.
            playbackStats.reset()
            return
        }
        val active = engine ?: return
        playbackStats.sample(
            nowMs = System.currentTimeMillis(),
            rendered = active.renderedFrameCount,
            dropped = active.droppedFrameCount,
        )?.let { logNative("playback $it") }
    }

    /**
     * Relays one short, credential-free note into Dart's **exportable**
     * diagnostics log, stamped with ms since this Activity started.
     *
     * Past `adopted=…` the whole native player used to be silent in an exported
     * log: no first frame, no stall, no reconnect, no engine swap. A user
     * reporting "high-bitrate channels stay black after going fullscreen" could
     * therefore send a complete, healthy-looking export of the exact session
     * that failed. Everything routed through here is chosen to be safe to
     * export verbatim — never a URL, header or provider reply.
     */
    private fun logNative(note: String) {
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native $note ms=${SystemClock.elapsedRealtime() - startedAtMs}",
        )
    }

    /**
     * The sink handed to whichever [ExoPlayerEngine] this Activity drives —
     * one it built, or the shared preview engine it adopted. Engines report
     * from the playback thread as well as the main one, so it hops.
     */
    private val diagnosticSink: (String) -> Unit = { note ->
        runOnUiThread { logNative(note) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        instance = WeakReference(this)
        startedAtMs = SystemClock.elapsedRealtime()
        // Gesture navigation and Android's system Back dispatcher terminate at
        // this same Activity boundary as remote key events. Do not register a
        // second Compose BackHandler: some TV images deliver one press through
        // both paths.
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = handleSystemBack()
            },
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Let the video reach the physical screen edge on a notched phone rather
        // than being letterboxed away from the cutout (the DEFAULT mode letterboxes
        // in landscape, which is exactly the orientation a player is used in). The
        // Compose overlay insets itself via safeDrawingPadding, so only the video
        // extends under the cutout — no control is ever placed there.
        // `ALWAYS` from API 30, `SHORT_EDGES` on 28–29. Android 15 deprecated
        // DEFAULT/SHORT_EDGES/NEVER (Play Console flags the use): with
        // edge-to-edge enforced from targetSdk 35 the window already extends
        // into the cutout, so the three modes that describe *not* doing that no
        // longer describe anything, and `ALWAYS` is the one that survives.
        // `ALWAYS` is public API from 30 only, so the older constant stays for
        // 28–29 — where it is not deprecated and is still the correct value.
        // Behaviour is unchanged either way: the video reaches the physical edge
        // instead of being letterboxed away from the cutout in landscape, and
        // the Compose overlay still insets itself via `safeDrawingPadding`, so
        // no control is ever placed under the cutout.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    } else {
                        @Suppress("DEPRECATION")
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
            }
        }
        hideSystemUi()

        PlayerStrings.language = intent.getStringExtra(EXTRA_APP_LANGUAGE) ?: "en"
        val streamUrl = intent.getStringExtra(EXTRA_URL)
        if (streamUrl.isNullOrBlank()) {
            finish()
            return
        }
        url = streamUrl
        headers = requestHeaders()
        subtitles = subtitleSpecs()
        bufferPreset = BufferPreset.fromName(intent.getStringExtra(EXTRA_BUFFER_PRESET))
        adaptiveBuffer = intent.getBooleanExtra("adaptiveBuffer", false)
        settingsSession = intent.getIntExtra("settingsSession", 0)
        qualityPreference = intent.getStringExtra("qualityPreference") ?: "auto"
        matchRefreshRate = intent.getBooleanExtra("matchRefreshRate", false)

        // Seamless handoff: when the live preview is already playing this exact
        // stream, adopt its running engine — only the video output moves to this
        // Activity's surface; audio, decoder and buffer carry over untouched.
        val shared = if (intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)) {
            SharedEngine.adoptForFullscreen(
                streamUrl,
                diagnosticSink,
                // Bound with the diagnostics, i.e. *before* the claim: it is
                // the claimed surface's own first frame that moves
                // FrameLivenessWatch off the first-frame clock, and inferring
                // it from the frame counter would fire during the deferred
                // claim, while the preview texture is still the output.
                onClaimedSurfaceFirstFrame = {
                    frameLiveness.markHandoffFirstFrame(System.currentTimeMillis())
                },
                requestedPreset = bufferPreset,
            )
        } else {
            null
        }
        adoptedShared = shared != null
        // The handoff's outcome, in the *exportable* log rather than logcat: a
        // refused adoption is a full stream reload, which is exactly what a user
        // reporting a slow, "reconnecting" preview→fullscreen transition sees.
        // Both halves are credential-free booleans.
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native fullscreen adoptShared=" +
                "${intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)} adopted=$adoptedShared",
        )

        uiState = shared?.second
            ?: PlayerUiState(
                title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false),
                sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME),
                isTv = isTelevision(),
                epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC),
                epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null),
            )
        if (shared != null) {
            // The adopted state was born for the faceless preview — fill in this
            // stream's presentation fields and reset any stale overlay state.
            uiState.title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
            uiState.isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false)
            uiState.sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME)
            uiState.isTv = isTelevision()
            uiState.epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC)
            uiState.epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null)
            uiState.controlsVisible = true
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            uiState.inPip = false
        }
        // Android TV's PiP framework restricts entry to communication/smartHome/health/ticker
        // use cases via a required manifest category — general media playback isn't an
        // approved category there, so FEATURE_PICTURE_IN_PICTURE is intentionally left
        // unused/absent for our purposes on most TVs. That's a platform limitation, not a bug:
        // the button below simply won't show on devices that report the feature missing.
        uiState.supportsPip = supportsPip()
        // Favorite toggle (live only): seeded from the Dart store, read back on
        // exit (see finish) so the channel list reflects it on return.
        // Opens on the mode Dart is already in (the user's stored choice, or a
        // platform default), rather than this class's own initial value — the
        // two overlays would otherwise disagree across the handoff.
        AspectMode.entries
            .firstOrNull { it.label == intent.getStringExtra(EXTRA_ASPECT) }
            ?.let { uiState.aspect = it }
        uiState.canFavorite = intent.getBooleanExtra(EXTRA_CAN_FAVORITE, false)
        uiState.isFavorite = intent.getBooleanExtra(EXTRA_IS_FAVORITE, false)
        // Whether a LiveZapController exists behind this route. Set here (not
        // only in the fresh-state branch above) because an adopted preview
        // state was born faceless and carries the *previous* session's value.
        // Fails closed: an older Dart build that doesn't send the key simply
        // offers no quick-list button, exactly as before.
        uiState.canZap = intent.getBooleanExtra(EXTRA_ZAP_ENABLED, false)
        uiState.currentEpisodeId = intent.getStringExtra(EXTRA_CURRENT_EPISODE_ID)
        uiState.episodes = runCatching {
            val rows = JSONArray(intent.getStringExtra(EXTRA_EPISODES) ?: "[]")
            (0 until rows.length()).mapNotNull { index ->
                val row = rows.optJSONObject(index) ?: return@mapNotNull null
                val id = row.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                TrackOption(id, row.optString("title").ifBlank { id })
            }.distinctBy { it.id }
        }.getOrDefault(emptyList())
        uiState.episodesOpen = false
        uiState.dvrAvailable = intent.getBooleanExtra(EXTRA_DVR_AVAILABLE, false)
        uiState.dvrActive = intent.getBooleanExtra(EXTRA_DVR_ACTIVE, false)
        adaptiveBuffer = adaptiveBuffer && uiState.isLive && !uiState.dvrActive
        adaptiveBufferPolicy.reset()
        dvrPlaybackId = intent.getLongExtra(EXTRA_DVR_PLAYBACK_ID, 0L)

        if (shared != null) {
            val sharedEngine = shared.first
            sharedEngine.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
            sharedEngine.onRecoverableError = { runOnUiThread { recoverPlaybackError() } }
            sharedEngine.onVideoSizeChanged = null
            setEngine(sharedEngine)
            configureAdaptiveBuffer(reset = true)
            // Fullscreen always plays unmuted, and resumes a paused preview.
            sharedEngine.setVolume(1f)
            sharedEngine.play()
            // The surface claim happened inside adoptForFullscreen above, and
            // the frames the preview drew before it are the proof
            // FrameLivenessWatch otherwise has to wait to observe — which, when
            // the handoff freezes the renderer before its first frame, never
            // arrives. Arming here is what turns that permanent silent freeze
            // into a stall the watchdog can act on. armed=false means the
            // engine reported no frames at all, so the inert rule still stands.
            val armed = frameLiveness.armHandoff(
                System.currentTimeMillis(),
                sharedEngine.renderedFrameCount,
            )
            logNative("handoff frame watch armed=$armed")
        } else {
            startWithExoPlayer()
            if (uiState.dvrActive) engine?.seekTo(0L)
            // VOD resume: jump to the saved position once the engine loads.
            // ExoPlayer remembers a seek issued right after load/prepare.
            val resumeMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L)
            if (resumeMs > 0L && !uiState.isLive) engine?.seekTo(resumeMs)
        }

        if (BuildConfig.DEBUG) {
            val soakAutoCloseMs = intent.getLongExtra(EXTRA_SOAK_AUTOCLOSE_MS, -1L)
            if (soakAutoCloseMs > 0L) {
                soakAutoCloseJob = lifecycleScope.launch {
                    delay(soakAutoCloseMs)
                    finish()
                }
            }
        }

        // The video view is hosted *by Compose* (`AndroidView` in [PlayerScreen]),
        // not attached here in `onCreate`. That was measured, not assumed: hoisting
        // it into a FrameLayout under the ComposeView changed nothing, because
        // `AndroidView` adds the SurfaceView during the first **composition**,
        // which happens inside the window's first traversal — the same traversal
        // that would lay out a pre-attached view. There is no second traversal to
        // save, and the ~150 ms between composition and `surfaceCreated` is
        // surface allocation, not scheduling. See docs/player.md.
        engine?.selectQuality(qualityPreference)
        setContent {
            engineState.value?.let { active ->
                PlayerScreen(
                    state = uiState,
                    videoView = active.view,
                    callbacks = playerCallbacks(),
                )
            }
        }
    }

    private fun startWithExoPlayer() {
        val exo = ExoPlayerEngine(
            context = this,
            state = uiState,
            headers = headers,
            // The field, not the Intent: a zap can change both the headers
            // (a cross-source zap) and the manual preset. Auto's current level
            // is driven through the existing LoadControl instance.
            bufferPreset = this.bufferPreset,
            adaptiveBuffer = adaptiveBuffer,
        )
        exo.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
        exo.onRecoverableError = { runOnUiThread { recoverPlaybackError() } }
        exo.onDiagnostic = diagnosticSink
        setEngine(exo)
        exo.load(url, subtitles)
    }

    /** One-way fallback: ExoPlayer couldn't decode the video → switch to libmpv. */
    private fun fallbackToMpv() {
        if (engine is MpvEngine || isFinishing) return
        val hardwareDecoding = (engine as? ExoPlayerEngine)
            ?.allowsHardwareMpvFallback() == true
        val keepPaused = uiState.dvrActive && (engine?.userPaused ?: !uiState.isPlaying)
        Log.i(TAG, "falling back to libmpv (video unsupported by ExoPlayer)")
        // An engine swap mid-session is a full stream reload on a channel the
        // user was already watching — very much part of "it stopped working
        // when I went fullscreen", and previously logcat-only.
        logNative("engine fallback from=exo to=mpv adopted=$adoptedShared")
        frameLiveness.reset()
        if (adoptedShared) {
            // The adopted engine can't decode this stream, so the shared preview
            // engine is dead too: release it through the holder, which tells the
            // Dart side to reset its preview state (it falls back to media_kit).
            adoptedShared = false
            SharedEngine.invalidateFromFullscreen(unsupported = true)
        } else {
            engine?.release()
        }
        // Reset stale stream info before the new engine repopulates it.
        uiState.videoUnsupported = false
        startWithMpv(hardwareDecoding = hardwareDecoding)
        if (keepPaused) engine?.pause()
    }

    /** Builds and loads an [MpvEngine] with the session's current locator. */
    private fun startWithMpv(hardwareDecoding: Boolean = false) {
        val mpv = MpvEngine(
            context = this,
            state = uiState,
            headers = headers,
            post = { action -> if (!isFinishing) runOnUiThread(action) },
            bufferPreset = this.bufferPreset,
            adaptiveBuffer = adaptiveBuffer,
            hardwareDecoding = hardwareDecoding,
        )
        setEngine(mpv)
        if (adaptiveBuffer) mpv.setAdaptiveBufferPreset(adaptiveBufferPolicy.effectivePreset)
        mpv.load(url, subtitles)
    }

    private fun setEngine(next: PlaybackEngine) {
        engine = next
        next.selectQuality(qualityPreference)
        engineState.value = next
    }

    private fun configureAdaptiveBuffer(reset: Boolean) {
        val active = engine ?: return
        if (reset) adaptiveBufferPolicy.reset()
        if (!active.configureAdaptiveBuffer(adaptiveBuffer, bufferPreset, reset)) {
            logNative("adaptive buffer unavailable on ${active.javaClass.simpleName}")
        }
    }

    private fun setDvrActive(active: Boolean) {
        if (uiState.dvrActive != active) adaptiveBufferPolicy.resetObservationWindow()
        uiState.dvrActive = active
    }

    fun stopForChannelSwitch() {
        resolveGate.abandon()
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        uiState.zapSettling = true
        zapSettlingSinceMs = System.currentTimeMillis()
        engine?.stop()
        uiState.fps = 0f
        refreshRateMatcher.restore()
        uiState.ended = false
    }

    fun applyPlaybackPreferences(args: Map<*, *>) {
        if ((args["settingsSession"] as? Number)?.toInt() != settingsSession) return
        qualityPreference = args["qualityPreference"] as? String ?: "auto"
        matchRefreshRate = args["matchRefreshRate"] == true
        val nextBufferPreset = BufferPreset.fromName(
            args["bufferPreset"] as? String ?: bufferPreset.name.lowercase(),
        )
        val nextAdaptiveBuffer =
            (args["adaptiveBuffer"] as? Boolean ?: adaptiveBuffer) &&
                uiState.isLive && !uiState.dvrActive
        bufferPreset = nextBufferPreset
        if (nextAdaptiveBuffer != adaptiveBuffer) {
            adaptiveBuffer = nextAdaptiveBuffer
            configureAdaptiveBuffer(reset = adaptiveBuffer)
        }
        (args["aspect"] as? String)?.let { label ->
            AspectMode.entries.firstOrNull { it.label == label }?.let {
                uiState.aspect = it
                engine?.applyAspect(it)
            }
        }
        engine?.selectQuality(qualityPreference)
        refreshRateMatcher.apply(matchRefreshRate, uiState.fps)
    }

    private fun showPlaybackSettings() {
        val session = settingsSession
        if (uiState.zapSettling) return
        MainActivity.instance?.get()?.requestPlaybackSettings(
            mapOf("settingsSession" to session,
                "qualities" to (engine?.videoQualities() ?: emptyList()),
                "height" to uiState.videoHeight),
        ) { result ->
            if (isFinishing || isDestroyed || session != settingsSession || uiState.zapSettling) return@requestPlaybackSettings
            val rows = (result as? List<*>)?.mapNotNull { value ->
                val row = value as? Map<*, *> ?: return@mapNotNull null
                val id = row["id"] as? String ?: return@mapNotNull null
                val label = row["label"] as? String ?: return@mapNotNull null
                TrackOption(id, label)
            }.orEmpty()
            if (rows.isNotEmpty()) {
                uiState.playbackOptions = rows
                uiState.infoOpen = false
                uiState.controlsVisible = true
                uiState.openMenu = PlayerMenu.Settings
            }
        }
    }

    /** Watchdog: reconnect a live stream that has stalled (buffering) or dropped (ended). */
    private fun pollLiveReconnect() {
        if (uiState.dvrActive) {
            if (uiState.ended && !uiState.dvrBusy && !dvrSuspended) {
                uiState.ended = false
                sendDvr("playbackEnded")
            }
            return
        }
        if (!uiState.isLive || uiState.dvrBusy || dvrSuspended) return
        // A re-resolve in flight *is* the reconnect, still in progress. Without
        // this the round trip would read as healthy and reset the backoff: the
        // engine sits in its terminal state (no further transition callback) and
        // `reconnectLive` already cleared `ended`, so both flags are false until
        // the reload actually starts.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        // A zap resolve in flight is not a stall: Dart is replacing this
        // stream on purpose (see [zapSettlingNow]).
        if (zapSettlingNow(now)) return
        // "Playing normally" by the engine's own account. When that is true and
        // no frame has reached the screen for NO_FRAME_STALL_MS, the account is
        // wrong — see [FrameLivenessWatch] for the failure it catches.
        val claimsHealthy =
            uiState.isPlaying && !uiState.isBuffering && !uiState.ended
        val frameStalled = frameLiveness.sample(
            nowMs = now,
            playingNormally = claimsHealthy,
            renderedFrames = engine?.renderedFrameCount ?: -1,
            // Proof of life the rendered count alone doesn't carry: a decoder
            // dropping frames is behind, not wedged, and no recovery this
            // watchdog can order makes a decoder faster.
            droppedFrames = engine?.droppedFrameCount ?: -1,
        )
        val stalled = uiState.isBuffering || uiState.ended || frameStalled
        observeAdaptiveBuffer(now, frameStalled)
        if (!stalled) {
            // Healthy playback: clear the stall clock and any reconnecting state.
            stalledSinceMs = 0L
            reconnectAttempt = 0
            stallKind = "none"
            if (uiState.reconnecting) uiState.reconnecting = false
            return
        }
        // A renderer frozen this soon after the fullscreen surface claim gets
        // the local fix first — reloading the stream to repair a decoder is
        // both slower and more expensive than repairing the decoder.
        if (frameStalled && tryHandoffDecoderRebuild(now)) return
        if (stalledSinceMs == 0L) stalledSinceMs = now
        // A frozen renderer needs no further grace period: the watch has
        // already waited out its own window while everything read healthy, so
        // requiring the stall threshold on top would double it.
        val threshold = when {
            frameStalled -> 0L
            uiState.ended -> ReconnectPolicy.ENDED_RECONNECT_MS
            else -> ReconnectPolicy.STALL_RECONNECT_MS
        }
        stallKind = when {
            frameStalled -> "noframes"
            uiState.ended -> "ended"
            else -> "buffering"
        }
        if (now - stalledSinceMs >= threshold) reconnectLive(force = false)
    }

    private fun observeAdaptiveBuffer(nowMs: Long, frameStalled: Boolean) {
        if (!adaptiveBuffer || !uiState.isLive || uiState.dvrActive || dvrSuspended) return
        val active = engine ?: return
        val next = adaptiveBufferPolicy.observe(
            nowMs = nowMs,
            playing = uiState.isPlaying && !uiState.isBuffering && !uiState.ended && !frameStalled,
            buffering = uiState.isBuffering,
            ended = uiState.ended,
            bufferAheadMs = active.bufferedAheadMs,
        ) ?: return
        if (!active.setAdaptiveBufferPreset(next)) {
            logNative("adaptive buffer update unavailable preset=${next.name.lowercase()}")
            return
        }
        logNative(
            "auto buffer preset=${next.name.lowercase()} aheadMs=${active.bufferedAheadMs}",
        )
    }

    /**
     * First rung of the recovery ladder for the preview→fullscreen handoff:
     * rebuild the video decoder in place instead of reloading the stream.
     *
     * The reports this answers are all the same session shape — an adopted
     * handoff, a claimed surface, and then either no picture at all or a
     * picture that stops within a second — and the exported logs behind them
     * all end the same way: the reload that eventually fired *fixed* it, on the
     * same URL (`refreshed=false`), on the same surface, after which the same
     * channel played for minutes without a drop. A stream and a device that
     * demonstrably work, through a decoder that stopped when its output surface
     * was switched under it. Nothing about that needs the network re-touched:
     * a reload spends a provider round trip and the whole buffer to build the
     * one thing that was actually broken, while carrying the risk that a
     * single-connection account refuses the new connection.
     *
     * Bounded to one attempt inside the handoff window ([FrameLivenessWatch]);
     * everything past that is the reload watchdog's, unchanged. Re-arms the
     * watch so a rebuild that *doesn't* restore the picture escalates on the
     * short handoff clock rather than the full six-second one.
     */
    private fun tryHandoffDecoderRebuild(nowMs: Long): Boolean {
        if (!frameLiveness.inHandoffWindow(nowMs)) return false
        if (handoffRebuilds >= MAX_HANDOFF_REBUILDS) return false
        val active = engine ?: return false
        // Counters first: after the rebuild they describe the new decoder, and
        // it is the frozen one's tallies that say *which* failure this was —
        // frames decoded and thrown away to catch up, or a decoder that had
        // stopped emitting entirely.
        val counters = active.videoFrameCounters
        // Which of the two handoff failures this was: a picture that never
        // arrived on the claimed surface, or one that arrived and stopped. They
        // are indistinguishable in the tallies (a single rendered frame is lost
        // in a preview's running total) and they are the two shapes the reports
        // keep alternating between, so the watch's own answer is worth a word.
        val phase = if (frameLiveness.drewSinceArm()) "afterFirstFrame" else "noFirstFrame"
        // How far into the handoff budget this fired. Without it a rebuild line
        // cannot be told apart from a rebuild that fired inside normal
        // first-frame latency — which is how two thresholds stayed wrong
        // through several exported logs.
        val sinceArm = frameLiveness.sinceArmMs(nowMs)
        if (!active.rebuildVideoDecoder()) return false
        handoffRebuilds++
        logNative(
            "handoff decoder rebuild attempt=$handoffRebuilds phase=$phase " +
                "sinceArmMs=$sinceArm" + (counters?.let { " $it" } ?: ""),
        )
        stalledSinceMs = 0L
        stallKind = "none"
        frameLiveness.armHandoff(nowMs, active.renderedFrameCount)
        return true
    }

    /**
     * Reload the live source to reconnect, with capped backoff between attempts.
     * [force] (a hard error) skips the stall threshold but still rate-limits.
     *
     * The reload goes through a **fresh locator** ([withFreshLiveLocator]):
     * Stalker `create_link` URLs carry single-use `play_token`s, so after a
     * portal-side kill the URL this Activity was launched with is permanently
     * dead and retrying it can never reconnect.
     */
    private fun reconnectLive(force: Boolean) {
        if (!uiState.isLive || isFinishing || uiState.dvrActive || uiState.dvrBusy || dvrSuspended) return
        // Single-flight: a re-resolve already in flight (this watchdog or the
        // user's "Go to live") owns the next reload. Bail *before* the attempt
        // bookkeeping so a suppressed attempt can't inflate the backoff; the
        // 500ms progress ticker re-enters once the in-flight request settles.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        if (zapSettlingNow(now)) return
        val sinceLast = now - lastReconnectMs
        val minGap = ReconnectPolicy.minGapMs(reconnectAttempt, force)
        if (lastReconnectMs != 0L && sinceLast < minGap) return
        reconnectAttempt++
        lastReconnectMs = now
        stalledSinceMs = now
        uiState.reconnecting = true
        uiState.ended = false
        Log.i(TAG, "live reconnect attempt=$reconnectAttempt force=$force")
        // Rate-limited above, so this is once per real attempt rather than once
        // per 500 ms tick. `kind` is what makes it worth exporting: an underrun,
        // a drop and a frozen renderer want completely different answers, and
        // all three used to arrive as the same silent black screen.
        logNative(
            "live reconnect attempt=$reconnectAttempt force=$force " +
                "kind=${if (force) "error" else stallKind}" +
                // Frame tallies at the moment of the decision: they are what
                // separate a decoder throwing frames away to catch up from one
                // that has stopped emitting, which read identically from every
                // health flag the engine exposes.
                (engine?.videoFrameCounters?.let { " $it" } ?: ""),
        )
        frameLiveness.reset()
        withFreshLiveLocator {
            // The round trip is asynchronous, so restart the stall clock when
            // the reload actually begins rather than when it was requested.
            stalledSinceMs = System.currentTimeMillis()
            engine?.load(url, subtitles)
        }
    }

    /**
     * Re-resolves the live locator through Dart, then runs [onFresh] with [url]
     * / [headers] updated in place. Returns false — doing nothing — when a
     * request is already in flight: provider accounts are single-connection, so
     * two overlapping `create_link` calls would fight over the one slot.
     *
     * Settlement is a race between the MethodChannel reply and a
     * [ResolveGate.TIMEOUT_MS] backstop, arbitrated by the gate's monotonic
     * token so exactly one of them applies an outcome and the loser is dropped.
     * The timeout is deliberately long: falling back early just reloads the
     * spent locator we already know is dead, which is strictly worse than
     * waiting. Any answer we can't use falls back to the current locator
     * ([ResolveAgainReply]), so this always ends in a reload attempt.
     */
    private fun withFreshLiveLocator(onFresh: () -> Unit): Boolean {
        val token = resolveGate.begin() ?: return false
        resolveTimeoutJob = lifecycleScope.launch {
            delay(ResolveGate.TIMEOUT_MS)
            resolveTimeoutJob = null
            settleFreshLiveLocator(token, reply = null, timedOut = true, onFresh = onFresh)
        }
        val host = MainActivity.instance?.get()
        if (host == null) {
            // No Flutter host to ask (it was destroyed under us) — settle now on
            // the current locator instead of waiting out the whole timeout.
            settleFreshLiveLocator(token, reply = null, timedOut = false, onFresh = onFresh)
        } else {
            host.requestFreshLiveLocator { reply ->
                settleFreshLiveLocator(token, reply, timedOut = false, onFresh = onFresh)
            }
        }
        return true
    }

    private fun settleFreshLiveLocator(
        token: Long,
        reply: Any?,
        timedOut: Boolean,
        onFresh: () -> Unit,
    ) {
        // Lost the race (or belongs to an already-settled request): discard.
        if (!resolveGate.settle(token)) return
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        // A reply can still land after teardown (the channel callback outlives
        // this Activity); nothing to reload then.
        if (isFinishing || isDestroyed) return
        val next = ResolveAgainReply.parse(reply, LiveLocator(url, headers))
        val refreshed = next.url != url
        url = next.url
        // Headers are baked into an engine's data-source factory at construction
        // (see SharedEngine.openPreview / MpvEngine), so this only takes effect
        // for a later engine build — an mpv fallback. Re-resolving the same
        // channel on the same source can't change them in practice; the
        // never-blank rule in ResolveAgainReply is what keeps a MAG User-Agent
        // from being dropped if a reply ever omits them.
        headers = next.headers
        // Never log the locator itself — provider URLs embed credentials. The
        // two booleans are safe and are what separate "the portal gave us a new
        // link and it still didn't play" from "we retried a locator we already
        // knew was dead because the round trip timed out".
        Log.i(TAG, "live re-resolve settled refreshed=$refreshed timedOut=$timedOut")
        logNative("live re-resolve refreshed=$refreshed timedOut=$timedOut")
        onFresh()
    }

    // ── Live zapping: applying what Dart decided ─────────────────────────────

    /**
     * Presentation-only push from Dart's zap controller, once per cursor move.
     *
     * Carries the **cursor's** channel, which during the settle window is
     * ahead of what is playing — that is the whole point of a banner. The
     * guide fields move with it for the same reason: while the user is
     * browsing, the strip should describe the channel they are browsing to.
     * [applyZap] puts both back in step when the move settles.
     */
    fun applyZapBanner(args: Map<*, *>) {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        uiState.channelNumber = (args["channelNumber"] as? Number)?.toInt()
        uiState.channelName = (args["channelName"] as? String)?.takeIf { it.isNotBlank() }
        uiState.digitBuffer = (args["digits"] as? String).orEmpty()
        zapDigitsPendingOptimistic = uiState.digitBuffer.isNotEmpty()
        uiState.zapMessage = (args["message"] as? String)?.takeIf { it.isNotBlank() }
        uiState.zapPosition = (args["position"] as? Number)?.toInt() ?: 0
        uiState.zapTotal = (args["total"] as? Number)?.toInt() ?: 0
        uiState.epgNow = epgFromMap(args, "epgNowTitle", "epgNowStartMs", "epgNowStopMs", "epgNowDesc")
        uiState.epgNext = epgFromMap(args, "epgNextTitle", "epgNextStartMs", "epgNextStopMs", null)
        val settling = args["settling"] as? Boolean ?: false
        uiState.zapSettling = settling
        zapSettlingSinceMs = if (settling) System.currentTimeMillis() else 0L
        uiState.zapBannerAtMs = System.currentTimeMillis()
        uiState.zapBannerVisible = true
    }

    /**
     * The quick list, pushed by Dart on every controller notification.
     *
     * Presentation only, like [applyZapBanner]: Dart owns the rows, the
     * cursor and the mode stack, and this is the parsed window
     * ([QuickListState.fromPayload], which never throws). A push with
     * `open:false` is a **tear-down instruction**, not an absence, so it is
     * applied exactly like any other.
     *
     * Opening it takes the screen from the chrome. That is not cosmetic: the
     * list claims the D-pad at the Activity boundary whatever the chrome is
     * doing ([ZapKeyPolicy]), so leaving the control row up would leave a
     * focused Compose button on screen that no arrow key can walk away from —
     * the same stranding "Go to live" once caused. Hiding the controls also
     * closes any open menu and the info panel through the overlay's existing
     * `controlsVisible` effect.
     */
    fun applyQuickList(args: Map<*, *>) {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        val next = QuickListState.fromPayload(args)
        val wasOpen = uiState.quickList.open
        uiState.quickList = next
        zapQuickListOpenOptimistic = next.open
        if (next.open && !wasOpen) {
            uiState.controlsVisible = false
        }
    }

    fun applyDvrState(args: Map<*, *>) {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return
        uiState.dvrAvailable = args["dvrAvailable"] as? Boolean ?: false
        setDvrActive(args["dvrActive"] as? Boolean ?: false)
        uiState.dvrBusy = args["dvrBusy"] as? Boolean ?: false
        uiState.dvrRecording = args["dvrRecording"] as? Boolean ?: false
        uiState.dvrStartMs = (args["dvrStartMs"] as? Number)?.toLong() ?: 0L
        uiState.dvrEndMs = (args["dvrEndMs"] as? Number)?.toLong() ?: 0L
        uiState.dvrPositionMs = (args["dvrPositionMs"] as? Number)?.toLong() ?: 0L
        uiState.dvrMessage = args["dvrMessage"] as? String ?: ""
        (args["liveSynced"] as? Boolean)?.let { uiState.liveSynced = it }
    }

    /** Stop first, then load only the local locator supplied by the Dart DVR. */
    fun applyDvrTransport(args: Map<*, *>): Boolean {
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return false
        when (args["action"]) {
            "stop" -> {
                dvrSuspended = true
                adaptiveBufferPolicy.resetObservationWindow()
                resolveGate.abandon()
                resolveTimeoutJob?.cancel()
                resolveTimeoutJob = null
                engine?.stop()
                uiState.isPlaying = false
                uiState.ended = false
            }
            "load" -> {
                val locator = (args["url"] as? String)?.takeIf { it.isNotBlank() } ?: return false
                setDvrActive(args["local"] == true)
                val nextHeaders = headerMapFrom(args["headers"])
                val rebuild = nextHeaders != headers || adoptedShared
                url = locator
                headers = nextHeaders
                subtitles = emptyList()
                dvrPlaybackId = (args["playbackId"] as? Number)?.toLong() ?: 0L
                if (rebuild) rebuildEngineForZap() else engine?.load(url, subtitles)
                if (args["local"] == true && engine is ExoPlayerEngine) engine?.seekTo(0L)
                if (args["paused"] == true) engine?.pause()
                dvrSuspended = false
                uiState.ended = false
                uiState.reconnecting = false
                frameLiveness.reset()
            }
            "toggle" -> engine?.playPause()
            "pause" -> engine?.pause()
            else -> return false
        }
        return true
    }

    private fun sendDvr(command: String, positionMs: Long? = null) {
        MainActivity.instance?.get()?.reportDvr(
            "nativeDvr",
            buildMap {
                put("command", command)
                put("playing", !(engine?.userPaused ?: !uiState.isPlaying))
                put("playbackId", dvrPlaybackId)
                positionMs?.let { put("positionMs", it) }
            },
        )
    }

    private fun recoverPlaybackError() {
        if (uiState.dvrBusy || dvrSuspended) return
        if (uiState.dvrActive) sendDvr("playbackError") else reconnectLive(force = true)
    }

    /**
     * Applies a settled zap: this Activity keeps playing, on the same surface,
     * with a new locator.
     *
     * Nothing here decides *which* channel — Dart already did, and already
     * resolved it. What the Activity owns is everything that would otherwise
     * be wrong the moment the stream underneath changes: an in-flight
     * re-resolve for the channel being left, an engine whose build-time
     * arguments no longer match, the shared engine's adoption key, and every
     * watchdog counter (the stop below is *ours*, not a drop).
     *
     * Never logs the locator or its headers — they carry account credentials.
     */
    fun applyZap(args: Map<*, *>): Map<String, Any> {
        val refused = mapOf<String, Any>("engineRebuilt" to false)
        if (!::uiState.isInitialized || isFinishing || isDestroyed) return refused
        val nextUrl = (args["url"] as? String)?.takeIf { it.isNotBlank() } ?: return refused
        dvrSuspended = false
        setDvrActive(args["dvrActive"] as? Boolean ?: false)
        dvrPlaybackId = (args["dvrPlaybackId"] as? Number)?.toLong() ?: 0L
        val nextHeaders = headerMapFrom(args["headers"])
        val nextPreset = BufferPreset.fromName(args["bufferPreset"] as? String)
        val nextAdaptiveBuffer = (args["adaptiveBuffer"] as? Boolean ?: false) &&
            (args["isLive"] as? Boolean ?: true) && !uiState.dvrActive

        // A re-resolve in flight describes the channel we are leaving, and its
        // continuation ends in `engine.load(url)` — letting it settle after
        // this would reload the previous channel on top of the new one, with
        // every health flag reading normal.
        resolveGate.abandon()
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null

        // Both are build-time arguments (the HTTP data-source factory and
        // `LoadControl`), so neither can be changed on a running engine — the
        // same reason `SharedEngine.openPreview` rebuilds on either.
        val rebuild = nextHeaders != headers || nextPreset != bufferPreset ||
            (uiState.dvrActive && adoptedShared)
        url = nextUrl
        headers = nextHeaders
        bufferPreset = nextPreset
        adaptiveBuffer = nextAdaptiveBuffer
        configureAdaptiveBuffer(reset = true)
        settingsSession = (args["settingsSession"] as? Number)?.toInt() ?: 0
        qualityPreference = args["qualityPreference"] as? String ?: "auto"
        matchRefreshRate = args["matchRefreshRate"] == true
        uiState.openMenu = PlayerMenu.None
        uiState.playbackOptions = emptyList()
        uiState.fps = 0f
        refreshRateMatcher.restore()
        // A zapped channel brings no external subtitle sidecars of its own
        // (the contract carries none), and keeping the launch channel's would
        // attach the wrong files to it.
        subtitles = emptyList()

        uiState.title = (args["title"] as? String).orEmpty()
        uiState.sourceName = args["sourceName"] as? String
        uiState.channelName = (args["channelName"] as? String)?.takeIf { it.isNotBlank() }
            ?: uiState.title.takeIf { it.isNotBlank() }
        uiState.channelNumber = (args["channelNumber"] as? Number)?.toInt()
        uiState.epgNow = epgFromMap(args, "epgNowTitle", "epgNowStartMs", "epgNowStopMs", "epgNowDesc")
        uiState.epgNext = epgFromMap(args, "epgNextTitle", "epgNextStartMs", "epgNextStopMs", null)
        uiState.canFavorite = args["canFavorite"] as? Boolean ?: false
        uiState.isFavorite = args["isFavorite"] as? Boolean ?: false
        (args["aspect"] as? String)?.let { label ->
            AspectMode.entries.firstOrNull { it.label == label }?.let { uiState.aspect = it }
        }
        uiState.digitBuffer = ""
        zapDigitsPendingOptimistic = false
        uiState.zapMessage = null
        uiState.zapSettling = false
        zapSettlingSinceMs = 0L
        uiState.zapBannerAtMs = System.currentTimeMillis()
        uiState.zapBannerVisible = true

        // The watchdog starts the new channel on a clean sheet: a full stall
        // threshold, a full backoff budget, and no handoff window — the
        // surface did not change, and no earlier frames say anything about
        // this decoder, so `reset()` (never `armHandoff`) is the honest state.
        frameLiveness.reset()
        playbackStats.reset()
        handoffRebuilds = 0
        stalledSinceMs = 0L
        lastReconnectMs = 0L
        reconnectAttempt = 0
        stallKind = "none"
        uiState.ended = false
        uiState.reconnecting = false
        uiState.liveSynced = true
        uiState.videoUnsupported = false

        if (rebuild) {
            rebuildEngineForZap()
        } else {
            // `load` stops first (see ExoPlayerEngine.load), which is what
            // frees a single-connection account's only slot before the new
            // stream opens.
            engine?.load(url, subtitles)
            engine?.applyAspect(uiState.aspect)
        }
        // Keep the adoption key in step, or a later `adoptForFullscreen` keys
        // off the channel this session was launched on. A no-op after a
        // rebuild, which has already un-adopted.
        SharedEngine.noteFullscreenZap(url, headers, bufferPreset)
        engine?.selectQuality(qualityPreference)
        if (uiState.dvrActive && engine is ExoPlayerEngine) engine?.seekTo(0L)
        logNative("zap applied rebuilt=$rebuild adopted=$adoptedShared")
        return mapOf("engineRebuilt" to rebuild)
    }

    /**
     * Replaces the engine because a zap changed something baked in at
     * construction (the headers of a cross-source zap, or the buffer preset).
     *
     * An **adopted** engine has to go through [SharedEngine.invalidateFromFullscreen]
     * rather than a bare `release()`: the preview owns that engine, and
     * releasing it behind the holder's back would leave `onDestroy`'s
     * `fullscreenDetached()` handing the preview a dead object. Same shape as
     * [fallbackToMpv], and it keeps `DebugCounters.exoEngines` /
     * `sharedEngineLive` balanced (release decrements, the fresh engine's
     * constructor increments).
     *
     * The engine *kind* is deliberately preserved: falling back to mpv is a
     * one-way, per-session decision about what this device can decode, and a
     * zap is not new evidence about that.
     */
    private fun rebuildEngineForZap() {
        val wasMpv = engine is MpvEngine
        if (adoptedShared) {
            adoptedShared = false
            SharedEngine.invalidateFromFullscreen(unsupported = false)
        } else {
            engine?.release()
        }
        if (wasMpv) startWithMpv() else startWithExoPlayer()
        engine?.applyAspect(uiState.aspect)
    }

    /** Coerces the channel codec's `Map<Object?, Object?>` header payload. */
    private fun headerMapFrom(raw: Any?): Map<String, String> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        return map.entries.mapNotNull { entry ->
            val key = entry.key as? String
            val value = entry.value
            if (key.isNullOrBlank() || value == null) null else key to value.toString()
        }.toMap()
    }

    /** [epgEntry]'s counterpart for a MethodChannel payload. */
    private fun epgFromMap(
        args: Map<*, *>,
        titleKey: String,
        startKey: String,
        stopKey: String,
        descKey: String?,
    ): com.gchofficial.iptvs.player.EpgEntry? {
        val title = (args[titleKey] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val start = (args[startKey] as? Number)?.toLong() ?: -1L
        val stop = (args[stopKey] as? Number)?.toLong() ?: -1L
        if (start < 0L || stop <= start) return null
        return com.gchofficial.iptvs.player.EpgEntry(
            title = title,
            startMs = start,
            stopMs = stop,
            description = descKey?.let { args[it] as? String }?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * True while Dart has a zap resolve in flight.
     *
     * The watchdog stands down for the duration: the stream it would be
     * reconnecting is one Dart is deliberately replacing, and a reconnect
     * would spend a second `create_link` on a single-connection account
     * against the channel being left. Bounded by the same timeout the resolve
     * round trip uses, so a `settling` that never gets its follow-up expires
     * instead of wedging the watchdog.
     */
    private fun zapSettlingNow(nowMs: Long): Boolean {
        val since = zapSettlingSinceMs
        if (since == 0L) return false
        if (nowMs - since >= ResolveGate.TIMEOUT_MS) {
            zapSettlingSinceMs = 0L
            if (::uiState.isInitialized) uiState.zapSettling = false
            return false
        }
        return true
    }

    private fun playerCallbacks() = PlayerCallbacks(
        onPlayPause = {
            if (uiState.isLive && uiState.dvrAvailable) {
                sendDvr("playPause")
            } else {
                if (uiState.isLive && uiState.isPlaying) uiState.liveSynced = false
                engine?.playPause()
            }
        },
        onSeekTo = {
            if (uiState.dvrActive) sendDvr("seek", it) else engine?.seekTo(it)
        },
        onSeekBy = {
            if (uiState.isLive && uiState.dvrAvailable) {
                sendDvr("seekBy", it)
            } else if (!uiState.isLive) {
                engine?.syncProgress()
                engine?.seekTo(PlayerInputPolicy.seekTarget(uiState.positionMs, uiState.durationMs, it))
            }
        },
        onSetVolume = { engine?.setVolume(it) },
        onToggleMute = { engine?.toggleMute() },
        onSelectAudio = { engine?.selectAudio(it) },
        onSelectSubtitle = { engine?.selectSubtitle(it) },
        onSetSpeed = { engine?.setSpeed(it) },
        onCycleAspect = {
            uiState.aspect = AspectMode.entries[(uiState.aspect.ordinal + 1) % AspectMode.entries.size]
            engine?.applyAspect(uiState.aspect)
            MainActivity.instance?.get()?.reportDvr("nativePlaybackAspect", mapOf(
                "settingsSession" to settingsSession, "aspect" to uiState.aspect.label,
            ))
        },
        // Live streams are typically non-seekable, so "go to live" reloads the
        // source — reconnecting drops the buffer and resumes at the live edge.
        // Re-resolves first, through the same single-flight gate the reconnect
        // watchdog uses: the locator may already be spent, and two concurrent
        // `create_link` calls would exceed a single-connection account.
        onGoLive = {
            if (uiState.dvrActive) {
                sendDvr("goLive")
            } else if (uiState.isLive) {
                val started = withFreshLiveLocator { engine?.load(url, subtitles) }
                if (started) uiState.liveSynced = true
            }
        },
        // Toggled locally **and** reported straight away.
        //
        // The close-time `RESULT_FAVORITE` stays — it is the only report
        // guaranteed to survive a kill — but it can only describe one channel,
        // and zapping means the star may be pressed on a channel this session
        // has since left. Dart applies both to whichever channel is current
        // when it hears them, and an absolute set is idempotent, so the two
        // cannot disagree.
        onToggleFavorite = {
            val next = !uiState.isFavorite
            uiState.isFavorite = next
            sendZap(if (next) "favorite:1" else "favorite:0")
        },
        onBack = { finish() },
        onEnterPip = { enterPip() },
        onZapCommand = { sendZap(it) },
        onStartTimeshift = { sendDvr("timeshift") },
        onToggleRecording = { sendDvr("record") },
        onPlaybackSettings = { showPlaybackSettings() },
        onSelectPlaybackSetting = { MainActivity.instance?.get()?.selectPlaybackSetting(it) },
        onSelectEpisode = { id ->
            if (uiState.hasEpisodes && id != uiState.currentEpisodeId &&
                uiState.episodes.any { it.id == id } && selectedEpisodeId == null
            ) {
                selectedEpisodeId = id
                engine?.syncProgress()
                finish()
            }
        },
    )

    override fun onStart() {
        super.onStart()
        progressTicker = lifecycleScope.launch {
            while (isActive) {
                engine?.syncProgress()
                refreshRateMatcher.apply(matchRefreshRate && hasWindowFocus(), uiState.fps)
                if (uiState.dvrActive && !dvrSuspended) {
                    MainActivity.instance?.get()?.reportDvr(
                        "nativeDvrPosition",
                        mapOf("positionMs" to (engine?.dvrPositionMs ?: uiState.positionMs), "playing" to !(engine?.userPaused ?: !uiState.isPlaying), "playbackId" to dvrPlaybackId),
                    )
                }
                pollLiveReconnect()
                samplePlaybackStats()
                // Faster while a frozen renderer is still attributable to the
                // fullscreen surface claim: that window is judged on
                // HANDOFF_POST_FRAME_STALL_MS, which the base cadence cannot
                // resolve (a single tick gap would decide it). Bounded by
                // HANDOFF_WINDOW_MS, so it costs five seconds per handoff and
                // nothing for the rest of the session.
                delay(
                    if (frameLiveness.inHandoffWindow(System.currentTimeMillis())) {
                        ReconnectPolicy.HANDOFF_POLL_MS
                    } else {
                        ReconnectPolicy.PROGRESS_TICK_MS
                    },
                )
            }
        }.also { job ->
            DebugCounters.incProgressTicker()
            // Fires exactly once whether the job is cancelled (onStop) or
            // completes on its own, so the counter can't double-decrement.
            job.invokeOnCompletion { DebugCounters.decProgressTicker() }
        }
    }

    override fun onResume() {
        super.onResume()
        DvrCaptureBridge.setForegroundActivity(this)
    }

    override fun onPause() {
        refreshRateMatcher.restore()
        DvrCaptureBridge.clearForegroundActivity(this)
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        DvrCaptureBridge.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onStop() {
        super.onStop()
        progressTicker?.cancel()
        progressTicker = null
        // Keep playing while in PiP (onStop can fire around the PiP window on
        // some devices); only pause when actually backgrounded. An adopted engine
        // on its way back to the preview keeps playing too — pausing here would
        // put an audio gap in an otherwise seamless return.
        if (!uiState.inPip && !(isFinishing && adoptedShared)) {
            if (uiState.dvrActive && !isFinishing) sendDvr("pausedByHost")
            engine?.pause()
        }
    }

    /** Home / recents while playing → enter picture-in-picture instead of
     *  backgrounding. No-op on devices without PiP (e.g. some Android TVs). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        enterPip()
    }

    /** Enters PiP if currently eligible; also invoked from a manual overlay button so entry
     *  doesn't depend solely on the OS calling [onUserLeaveHint] (inconsistent across OEMs). */
    private fun enterPip() {
        if (uiState.inPip || isFinishing || !uiState.isPlaying) return
        if (!supportsPip()) return
        try {
            enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            Log.e(TAG, "enterPictureInPictureMode failed", e)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) enteredPip = true
        uiState.inPip = isInPictureInPictureMode
        if (isInPictureInPictureMode) {
            // Collapse all chrome so the PiP window is video-only.
            uiState.controlsVisible = false
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            // Behind the PiP window sits MainActivity's task showing the black
            // Flutter handoff route — recede *that* task so the launcher shows
            // instead. It must be moved via MainActivity: entering PiP reparents
            // this Activity into its own pinned task, so moveTaskToBack(false)
            // from here would send the PiP window itself to the back (black
            // screen all around — the original 0.1.13 bug).
            MainActivity.instance?.get()?.moveTaskToBack(true)
        }
    }

    private fun supportsPip(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams {
        val w = uiState.videoWidth
        val h = uiState.videoHeight
        // Android rejects extreme ratios; clamp to its allowed band, default 16:9.
        val ratio = if (w > 0 && h > 0) {
            Rational(w, h).coerceRatio()
        } else {
            Rational(16, 9)
        }
        return PictureInPictureParams.Builder().setAspectRatio(ratio).build()
    }

    /** Clamp to Android's accepted aspect band (~0.418..2.39) to avoid a crash. */
    private fun Rational.coerceRatio(): Rational {
        val value = numerator.toDouble() / denominator.toDouble()
        return when {
            value < 0.42 -> Rational(42, 100)
            value > 2.39 -> Rational(239, 100)
            else -> this
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { playerCallbacks().onPlayPause(); return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                playerCallbacks().onSeekBy(10_000); return true
            }
            KeyEvent.KEYCODE_MEDIA_REWIND -> {
                playerCallbacks().onSeekBy(-10_000); return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /**
     * Every exit path funnels through finish() (including system Back via the
     * dispatcher), so report the final playback position here — the Dart side
     * persists it as the VOD resume point when [MainActivity] relays it on
     * `nativeClosed`.
     */
    override fun finish() {
        if (::uiState.isInitialized) {
            val result = Intent()
            var hasResult = false
            selectedEpisodeId?.let { result.putExtra(RESULT_SELECTED_EPISODE_ID, it) }
            if (!uiState.isLive) {
                result.putExtra(RESULT_POSITION_MS, uiState.positionMs)
                result.putExtra(RESULT_DURATION_MS, uiState.durationMs)
                hasResult = true
            }
            // Report the final favorite state (live or VOD) so Dart can persist
            // it — this is the only channel back to the store from this Activity.
            if (uiState.canFavorite) {
                result.putExtra(RESULT_FAVORITE, uiState.isFavorite)
                hasResult = true
            }
            // The aspect the user left the player in, so the choice outlives
            // this Activity — Dart persists it per source. Reported for VOD
            // too, unlike the favorite: framing is a property of the source,
            // and a mode chosen while watching a film is just as deliberate as
            // one chosen on a channel.
            result.putExtra(RESULT_ASPECT, uiState.aspect.label)
            hasResult = true
            if (hasResult) setResult(RESULT_OK, result)
        }
        // Dart may resolve the chosen episode as soon as nativeClosed arrives,
        // before this Activity reaches onDestroy. Release the old transport now.
        if (selectedEpisodeId != null) engine?.stop()
        // Hand the adopted engine back *now*, not in onDestroy. The result
        // above reaches Dart as soon as MainActivity resumes, while onDestroy
        // of a finishing Activity waits for the next one to go idle — on a
        // busy TV box, seconds. A zapped session's return leg (stop,
        // re-resolve, open the ended channel) ran entirely inside that gap and
        // found the engine still adopted; and an un-zapped return sat on the
        // preview's frozen last frame until it closed.
        handBackSharedEngine()
        if (enteredPip) restoreMainTaskAfterPip()
        super.finish()
    }

    /**
     * Returns an adopted engine to the preview. Idempotent: [finish] calls it
     * first, and [onDestroy] covers any exit that never went through finish.
     * [engine] is dropped with it, so nothing in this Activity's remaining
     * lifetime (onStop's pause, a straggling ticker) can touch an engine the
     * preview now owns.
     */
    private fun handBackSharedEngine() {
        if (!adoptedShared) return
        adoptedShared = false
        engine?.selectQuality("auto")
        engine = null
        SharedEngine.fullscreenDetached()
    }

    /**
     * PiP places this Activity in a pinned task and the Flutter task is moved
     * behind the launcher on entry.  Reorder the already-running MainActivity
     * task before finishing so nativeClosed is delivered into the visible
     * Flutter route rather than leaving the user at the home screen.
     */
    private fun restoreMainTaskAfterPip() {
        if (MainActivity.instance?.get() == null) return
        try {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ),
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not restore Flutter task after PiP", e)
        }
    }

    override fun onDestroy() {
        refreshRateMatcher.restore()
        if (instance?.get() === this) instance = null
        soakAutoCloseJob?.cancel()
        soakAutoCloseJob = null
        // lifecycleScope cancels this anyway; dropping the reference here also
        // releases the captured reload callback immediately.
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        if (adoptedShared) {
            // Not ours to release: hand the video output back to the preview
            // surface; the engine keeps playing across the return.
            handBackSharedEngine()
        } else {
            engine?.release()
        }
        engine = null
        super.onDestroy()
    }

    private fun requestHeaders(): Map<String, String> {
        val keys = intent.getStringArrayListExtra(EXTRA_HEADER_KEYS).orEmpty()
        val values = intent.getStringArrayListExtra(EXTRA_HEADER_VALUES).orEmpty()
        return keys.mapIndexedNotNull { index, key ->
            val value = values.getOrNull(index)
            if (key.isBlank() || value.isNullOrBlank()) null else key to value
        }.toMap()
    }

    private fun subtitleSpecs(): List<SubtitleSpec> {
        val urls = intent.getStringArrayListExtra(EXTRA_SUBTITLE_URLS).orEmpty()
        val labels = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LABELS).orEmpty()
        val languages = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LANGUAGES).orEmpty()
        return urls.mapIndexedNotNull { index, subUrl ->
            if (subUrl.isBlank()) {
                null
            } else {
                SubtitleSpec(
                    url = subUrl,
                    label = labels.getOrNull(index).orEmpty(),
                    language = languages.getOrNull(index).orEmpty(),
                )
            }
        }
    }

    /**
     * Ten-foot player chrome. Shares [isTelevisionDevice] with `MainActivity`'s
     * `iptvs/device` answer so the player and the browsing layout can't
     * disagree — they did once, and the result was a set-top box with a
     * two-pane channel list and handset-sized player controls.
     */
    private fun isTelevision(): Boolean = isTelevisionDevice(this)

    /** Builds an [com.gchofficial.iptvs.player.EpgEntry] from intent extras, or null if absent/invalid. */
    private fun epgEntry(
        titleKey: String,
        startKey: String,
        stopKey: String,
        descKey: String?,
    ): com.gchofficial.iptvs.player.EpgEntry? {
        val title = intent.getStringExtra(titleKey)?.takeIf { it.isNotBlank() } ?: return null
        val start = intent.getLongExtra(startKey, -1L)
        val stop = intent.getLongExtra(stopKey, -1L)
        if (start < 0L || stop <= start) return null
        return com.gchofficial.iptvs.player.EpgEntry(
            title = title,
            startMs = start,
            stopMs = stop,
            description = descKey?.let { intent.getStringExtra(it) }?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * Immersive fullscreen, via the supported inset API.
     *
     * The old `systemUiVisibility` flag set has been deprecated since API 30, and
     * from targetSdk 35 its `LAYOUT_*` half is meaningless anyway: edge-to-edge is
     * enforced and `setDecorFitsSystemWindows` is disabled, so the window already
     * extends behind the bars. [WindowInsetsControllerCompat] is the replacement;
     * `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` reproduces `IMMERSIVE_STICKY` — a
     * swipe reveals the bars transiently and they hide themselves again.
     *
     * [WindowCompat.setDecorFitsSystemWindows] is kept for API 26–34, where it is
     * still what makes the window lay out edge-to-edge (it is the no-op on 35+,
     * not the other way round).
     */
    private fun hideSystemUi() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    companion object {
        /**
         * The live player Activity, while one exists.
         *
         * [MainActivity] routes the inbound zap methods (`zapTo`,
         * `setZapBanner`, `setQuickList`) here: they are Dart→native pushes
         * for a *running*
         * player, and a MethodChannel can only be registered once per process
         * — so the channel handler stays in `MainActivity` and forwards, the
         * same shape `logPlaybackDiagnostic` already uses in the other
         * direction.
         */
        var instance: WeakReference<HdrPlayerActivity>? = null
            private set

        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_APP_LANGUAGE = "app_language"
        const val EXTRA_IS_LIVE = "is_live"
        const val EXTRA_EPISODES = "episodes"
        const val EXTRA_CURRENT_EPISODE_ID = "current_episode_id"
        const val EXTRA_DVR_AVAILABLE = "dvr_available"
        const val EXTRA_DVR_ACTIVE = "dvr_active"
        const val EXTRA_DVR_PLAYBACK_ID = "dvr_playback_id"
        const val EXTRA_SOURCE_NAME = "source_name"
        const val EXTRA_EPG_NOW_TITLE = "epg_now_title"
        const val EXTRA_EPG_NOW_START = "epg_now_start"
        const val EXTRA_EPG_NOW_STOP = "epg_now_stop"
        const val EXTRA_EPG_NOW_DESC = "epg_now_desc"
        const val EXTRA_EPG_NEXT_TITLE = "epg_next_title"
        const val EXTRA_EPG_NEXT_START = "epg_next_start"
        const val EXTRA_EPG_NEXT_STOP = "epg_next_stop"
        const val EXTRA_HEADER_KEYS = "header_keys"
        const val EXTRA_HEADER_VALUES = "header_values"
        const val EXTRA_SUBTITLE_URLS = "subtitle_urls"
        const val EXTRA_SUBTITLE_LABELS = "subtitle_labels"
        const val EXTRA_SUBTITLE_LANGUAGES = "subtitle_languages"

        /** Adopt the shared preview engine instead of loading fresh (see [SharedEngine]). */
        const val EXTRA_ADOPT_SHARED = "adopt_shared"
        const val EXTRA_BUFFER_PRESET = "buffer_preset"
        const val EXTRA_ASPECT = "aspect"

        /** VOD resume: start playback at this position (ms), 0 = from the top. */
        const val EXTRA_RESUME_MS = "resume_ms"

        /**
         * Debug-only: auto-`finish()` this many ms after open, so an
         * integration-test soak can cycle the Activity unattended. Read only
         * when [BuildConfig.DEBUG]; absent/non-positive means never scheduled.
         */
        const val EXTRA_SOAK_AUTOCLOSE_MS = "soak_autoclose_ms"

        /** Favorite toggle (live channels): whether to show the star + its seed state. */
        const val EXTRA_CAN_FAVORITE = "can_favorite"
        const val EXTRA_IS_FAVORITE = "is_favorite"
        const val EXTRA_ZAP_ENABLED = "zap_enabled"

        /** Result extras: final position/duration + favorite, for the Dart stores. */
        const val RESULT_POSITION_MS = "position_ms"
        const val RESULT_DURATION_MS = "duration_ms"
        const val RESULT_FAVORITE = "favorite"
        const val RESULT_ASPECT = "aspect"
        const val RESULT_SELECTED_EPISODE_ID = "selected_episode_id"

        /**
         * Local decoder rebuilds allowed per handoff. One: a second would be a
         * loop with a stall threshold, and the failure it treats is a
         * one-time event (a surface switch) that a rebuild either survives or
         * doesn't. See [tryHandoffDecoderRebuild].
         */
        private const val MAX_HANDOFF_REBUILDS = 1
        private const val TAG = "iptvs.hdr"
    }
}
