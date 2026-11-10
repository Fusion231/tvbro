package com.gchofficial.iptvs

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.isTelevisionDevice
import com.gchofficial.iptvs.player.BufferPreset
import com.gchofficial.iptvs.player.PlayerStrings
import com.gchofficial.iptvs.player.ProviderRejection
import com.gchofficial.iptvs.player.SharedEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONArray

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var nativeHdrChannel: MethodChannel
    private lateinit var previewChannel: MethodChannel
    private lateinit var updatesChannel: MethodChannel
    private lateinit var deviceChannel: MethodChannel
    private lateinit var keyboardChannel: MethodChannel
    private var keyboardVisible = false
    private var pendingInstallPermissionResult: MethodChannel.Result? = null

    /**
     * Answers the `iptvs/device` channel's `isTelevision`, which two Dart
     * callers use: the pairing screen's suggested device label, and — since it
     * decides the *layout* — the wide/narrow choice resolved at boot
     * (`device_class.dart`, `isWideLayout`).
     *
     * Shared with `HdrPlayerActivity`'s ten-foot player chrome via
     * [isTelevisionDevice], deliberately: the two must never disagree about
     * what kind of device this is.
     */
    private fun isTelevision(): Boolean = isTelevisionDevice(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
        // A floating TV IME reports zero bottom inset even while visible.
        // Observe visibility on FlutterView's parent, leaving the engine's own
        // insets listener (and its keyboard animation handling) intact.
        val content = findViewById<android.view.View>(android.R.id.content)
        ViewCompat.setOnApplyWindowInsetsListener(content) { _, insets ->
            val visible = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (keyboardVisible && !visible && ::keyboardChannel.isInitialized) {
                keyboardChannel.invokeMethod("hidden", null)
            }
            keyboardVisible = visible
            insets
        }
        ViewCompat.requestApplyInsets(content)
    }

    override fun onStop() {
        super.onStop()
        AppSession.activityStopped(this, this, isChangingConfigurations)
        // Back-exit safety net: leaving the app must never strand the shared
        // preview engine playing audio behind the launcher. Dart also stops it
        // on lifecycle-pause, but the engine is process-global and outlives the
        // Flutter UI, so the finishing Activity enforces it too. Not adopted =
        // not owned by a fullscreen HdrPlayerActivity.
        if (isFinishing && !SharedEngine.adoptedByFullscreen) {
            SharedEngine.invalidate()
        }
    }

    override fun onStart() {
        super.onStart()
        if (AppSession.activityStarted(this, this)) closeInactivePlayback()
    }

    private fun closeInactivePlayback() {
        HdrPlayerActivity.instance?.get()?.finishForInactivity()
        SharedEngine.stopPreview()
    }

    override fun onResume() {
        super.onResume()
        DvrCaptureBridge.setForegroundActivity(this)
    }

    override fun onPause() {
        DvrCaptureBridge.clearForegroundActivity(this)
        super.onPause()
    }

    override fun onDestroy() {
        AppSession.activityDestroyed(this, this, isChangingConfigurations)
        ViewCompat.setOnApplyWindowInsetsListener(
            findViewById<android.view.View>(android.R.id.content),
            null,
        )
        if (instance?.get() === this) instance = null
        pendingInstallPermissionResult?.success(false)
        pendingInstallPermissionResult = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        DvrCaptureBridge.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptvs/app_session")
            .setMethodCallHandler { call, result ->
                if (call.method == "consumeInactivityReset") {
                    if (AppSession.resetPending(this)) closeInactivePlayback()
                    result.success(AppSession.consumeReset(this))
                } else {
                    result.notImplemented()
                }
            }
        keyboardChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/keyboard",
        )
        DvrCaptureBridge.register(this, flutterEngine)

        // The live preview's video surface (a TextureView the shared ExoPlayer
        // engine renders into) — embedded in the Flutter channel list.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "iptvs/preview_view",
            PreviewViewFactory(),
        )

        // Drives the shared preview engine (see SharedEngine). Separate channel
        // from the fullscreen player's because each channel has one Dart-side
        // method-call handler, and PlayerScreen owns the other one.
        previewChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_preview",
        )
        previewChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }
                    PlayerStrings.language = args["appLanguage"] as? String ?: "en"
                    val headers = (args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
                        .entries.mapNotNull { entry ->
                            val key = entry.key as? String
                            if (key.isNullOrBlank()) null else key to entry.value.toString()
                        }.toMap()
                    val requestId = (args["requestId"] as? Number)?.toLong()
                    SharedEngine.onPreviewError = { rejection ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "error", "message" to rejection.toString(), "requestId" to requestId) +
                                rejection.eventFields(),
                        )
                    }
                    SharedEngine.onPreviewUnsupported = {
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "unsupported", "requestId" to requestId),
                        )
                    }
                    SharedEngine.onPreviewLost = { unsupported ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "lost", "unsupported" to unsupported, "requestId" to requestId),
                        )
                    }
                    SharedEngine.onPreviewRecover = { reason ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "recover", "reason" to reason, "requestId" to requestId),
                        )
                    }
                    SharedEngine.openPreview(
                        this,
                        url,
                        headers,
                        args["muted"] as? Boolean ?: true,
                        BufferPreset.fromName(args["bufferPreset"] as? String),
                    )
                    result.success(true)
                }

                "play" -> {
                    SharedEngine.playPreview()
                    result.success(true)
                }

                "pause" -> {
                    SharedEngine.pausePreview()
                    result.success(true)
                }

                "setVolume" -> {
                    val args = call.arguments as? Map<*, *>
                    val volume = (args?.get("volume") as? Number)?.toFloat()
                    if (volume != null) SharedEngine.setPreviewVolume(volume.coerceIn(0f, 1f))
                    result.success(true)
                }

                "stop" -> {
                    SharedEngine.stopPreview()
                    result.success(true)
                }

                "stopForChannelSwitch" -> {
                    SharedEngine.stopForChannelSwitch()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        nativeHdrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_hdr_player",
        )
        nativeHdrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val openStartedAtMs = SystemClock.elapsedRealtime()
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }

                    val headers = args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val headerPairs = headers.entries.mapNotNull { entry ->
                        val key = entry.key as? String
                        if (key.isNullOrBlank()) null else key to entry.value.toString()
                    }
                    val subtitles = args["subtitles"] as? List<*> ?: emptyList<Any>()
                    val subtitleRows = subtitles.mapNotNull { entry ->
                        val map = entry as? Map<*, *> ?: return@mapNotNull null
                        val url = map["url"] as? String
                        if (url.isNullOrBlank()) {
                            null
                        } else {
                            Triple(
                                url,
                                map["label"]?.toString() ?: "",
                                map["language"]?.toString() ?: "",
                            )
                        }
                    }
                    fun epochMs(key: String): Long = (args[key] as? Number)?.toLong() ?: -1L
                    val episodeToken = try {
                        (args["episodes"] as? List<*>)?.let {
                            holdEpisodeMetadata(this, JSONArray(it).toString())
                        }
                    } catch (_: Exception) {
                        result.error("native_open_failed", "Could not prepare episode metadata", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(this, HdrPlayerActivity::class.java).apply {
                        putExtra(AppSession.EXTRA_GENERATION, AppSession.generation(this@MainActivity))
                        putExtra(HdrPlayerActivity.EXTRA_OPEN_STARTED_AT_MS, openStartedAtMs)
                        putExtra("nativeOpenId", (args["nativeOpenId"] as? Number)?.toLong() ?: 0L)
                        putExtra(HdrPlayerActivity.EXTRA_URL, url)
                        putExtra(HdrPlayerActivity.EXTRA_TITLE, args["title"] as? String ?: "")
                        putExtra(HdrPlayerActivity.EXTRA_APP_LANGUAGE, args["appLanguage"] as? String ?: "en")
                        putExtra(HdrPlayerActivity.EXTRA_IS_LIVE, args["isLive"] as? Boolean ?: false)
                        // Seamless handoff: adopt the shared preview engine already
                        // playing this stream instead of reloading it.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ADOPT_SHARED,
                            args["adoptShared"] as? Boolean ?: false,
                        )
                        // Per-source buffering. Without this the Activity reads
                        // a null extra and builds every fullscreen engine on
                        // NORMAL, so the setting only ever reached the preview.
                        putExtra(
                            HdrPlayerActivity.EXTRA_BUFFER_PRESET,
                            args["bufferPreset"] as? String,
                        )
                        putExtra("adaptiveBuffer", args["adaptiveBuffer"] as? Boolean ?: false)
                        putExtra(HdrPlayerActivity.EXTRA_ASPECT, args["aspect"] as? String)
                        putExtra("settingsSession", (args["settingsSession"] as? Number)?.toInt() ?: 0)
                        putExtra("qualityPreference", args["qualityPreference"] as? String ?: "auto")
                        putExtra("matchRefreshRate", args["matchRefreshRate"] == true)
                        // VOD resume point (ms), 0 = play from the top.
                        putExtra(
                            HdrPlayerActivity.EXTRA_RESUME_MS,
                            (args["resumeMs"] as? Number)?.toLong() ?: 0L,
                        )
                        // Favorite toggle (live channels): whether to show the
                        // star, and its seed state from the Dart favorites store.
                        putExtra(
                            HdrPlayerActivity.EXTRA_CAN_FAVORITE,
                            args["canFavorite"] as? Boolean ?: false,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_IS_FAVORITE,
                            args["isFavorite"] as? Boolean ?: false,
                        )
                        // Whether this route has a LiveZapController behind it.
                        // Constant for the life of the route, so it rides the
                        // open Intent rather than a live channel — the Android
                        // twin of the Windows overlay's `zapEnabled` key on
                        // setControlState. Fails closed: absent means no zap
                        // affordance, never a button that does nothing.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ZAP_ENABLED,
                            args["zapEnabled"] as? Boolean ?: false,
                        )
                        putExtra(HdrPlayerActivity.EXTRA_DVR_AVAILABLE, args["dvrAvailable"] as? Boolean ?: false)
                        putExtra(HdrPlayerActivity.EXTRA_EPISODES_TOKEN, episodeToken)
                        putExtra(HdrPlayerActivity.EXTRA_CURRENT_EPISODE_ID, args["currentEpisodeId"] as? String)
                        putExtra(HdrPlayerActivity.EXTRA_DVR_ACTIVE, args["dvrActive"] as? Boolean ?: false)
                        putExtra(HdrPlayerActivity.EXTRA_DVR_PLAYBACK_ID, (args["dvrPlaybackId"] as? Number)?.toLong() ?: 0L)
                        (args["sourceName"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_SOURCE_NAME, it)
                        }
                        // Debug-only integration-test soak: lets a test cycle the
                        // native Activity unattended. Never read outside a debug
                        // build (see HdrPlayerActivity), so gate it here too rather
                        // than carry it onto a release-build intent for no reason.
                        if (BuildConfig.DEBUG) {
                            (args["soakAutoCloseMs"] as? Number)?.toLong()?.let {
                                putExtra(HdrPlayerActivity.EXTRA_SOAK_AUTOCLOSE_MS, it)
                            }
                        }
                        // Live EPG now/next snapshot (epoch ms passed as doubles).
                        (args["epgNowTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_START, epochMs("epgNowStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_STOP, epochMs("epgNowStopMs"))
                            (args["epgNowDesc"] as? String)?.let { d ->
                                putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_DESC, d)
                            }
                        }
                        (args["epgNextTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_START, epochMs("epgNextStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_STOP, epochMs("epgNextStopMs"))
                        }
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_KEYS,
                            ArrayList(headerPairs.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_VALUES,
                            ArrayList(headerPairs.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_URLS,
                            ArrayList(subtitleRows.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LABELS,
                            ArrayList(subtitleRows.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LANGUAGES,
                            ArrayList(subtitleRows.map { it.third }),
                        )
                    }
                    val preparedAtMs = SystemClock.elapsedRealtime()
                    try {
                        startActivityForResult(intent, REQUEST_NATIVE_PLAYER)
                    } catch (_: Exception) {
                        releaseEpisodeMetadata(this, intent.getStringExtra(HdrPlayerActivity.EXTRA_EPISODES_TOKEN))
                        result.error("native_open_failed", "Could not open native player", null)
                        return@setMethodCallHandler
                    }
                    logPlaybackDiagnostic(
                        "native startup launch preparedMs=${preparedAtMs - openStartedAtMs} " +
                            "dispatchMs=${SystemClock.elapsedRealtime() - preparedAtMs} " +
                            "episodes=${(args["episodes"] as? List<*>)?.size ?: 0}",
                    )
                    result.success(true)
                }

                // ── Live zapping (Dart → the running player Activity) ────
                //
                // Dart owns the channel list, the cursor and the resolve (see
                // `lib/player/live_zap_controller.dart`); these two are the
                // only things it asks the native side to *do*. The channel
                // handler has to live here — a MethodChannel is registered
                // once per process — so both forward to the live Activity,
                // the mirror of `logPlaybackDiagnostic` going the other way.
                //
                // Both are no-ops with no Activity up: a zap that arrives
                // after the player closed has nothing to apply, and answering
                // `false` rather than erroring keeps a late push off Dart's
                // error path.
                "zapTo" -> {
                    val args = call.arguments as? Map<*, *>
                    val player = HdrPlayerActivity.instance?.get()
                    if (args == null || player == null) {
                        result.success(mapOf("engineRebuilt" to false))
                    } else {
                        result.success(player.applyZap(args))
                    }
                }

                "setZapBanner" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyZapBanner(args)
                    }
                    result.success(true)
                }

                "confirmProviderStreamWarning" -> {
                    val args = call.arguments as? Map<*, *>
                    val player = HdrPlayerActivity.instance?.get()
                    if (args == null || player == null) {
                        result.success(false)
                    } else {
                        player.confirmProviderStreamWarning(args) { result.success(it) }
                    }
                }

                "close" -> {
                    HdrPlayerActivity.instance?.get()?.finish()
                    result.success(true)
                }

                "applyPlaybackPreferences" -> {
                    (call.arguments as? Map<*, *>)?.let {
                        HdrPlayerActivity.instance?.get()?.applyPlaybackPreferences(it)
                    }
                    result.success(null)
                }
                "replaceMedia" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(args != null && HdrPlayerActivity.instance?.get()?.replaceMedia(args) == true)
                }
                "episodeSwitchFailed" -> {
                    (call.arguments as? Map<*, *>)?.let { HdrPlayerActivity.instance?.get()?.episodeSwitchFailed(it) }
                    result.success(null)
                }
                "stopForChannelSwitch" -> {
                    val player = HdrPlayerActivity.instance?.get()
                    val checkpoint = player?.stopForChannelSwitch()
                    if ((call.arguments as? Map<*, *>)?.get("checkpoint") == true && player != null && checkpoint != null) {
                        player.whenTransportStopped(
                            onStopped = { result.success(checkpoint) },
                            onTimeout = { result.error("stop_timeout", "Previous stream has not stopped", null) },
                        )
                    } else result.success(null)
                }
                "setDvrState" -> {
                    (call.arguments as? Map<*, *>)?.let {
                        HdrPlayerActivity.instance?.get()?.applyDvrState(it)
                    }
                    result.success(true)
                }

                "dvrTransport" -> {
                    val args = call.arguments as? Map<*, *>
                    val player = HdrPlayerActivity.instance?.get()
                    result.success(args != null && player != null && player.applyDvrTransport(args))
                }

                // The quick list's row window, routed exactly like the banner
                // beside it. Every push is forwarded, including the closing
                // one: `open:false` is a tear-down instruction, not an
                // absence (`HdrPlayerActivity.applyQuickList`).
                "setQuickList" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyQuickList(args)
                    }
                    result.success(true)
                }

                // Debug-only lifecycle counters for an integration-test soak
                // (see DebugCounters); empty map in a release build.
                "debugCounters" -> result.success(DebugCounters.snapshot())
                "debugPlaybackState" -> result.success(
                    if (BuildConfig.DEBUG || BuildConfig.BUILD_TYPE == "profile")
                        HdrPlayerActivity.instance?.get()?.debugPlaybackState() ?: emptyMap<String, Any>()
                    else emptyMap<String, Any>(),
                )

                else -> result.notImplemented()
            }
        }

        // Device form factor, read once while pairing so the device can suggest
        // its own name ("Android TV" vs "Android") to the web panel. Outbound
        // only — Dart never registers a handler here, so this is not a
        // ChannelHandlerOwner case.
        deviceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/device",
        )
        deviceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())
                "stableIdentity" -> {
                    // This app/signing-key/user-scoped ID stays inside the app.
                    // Dart hashes the scope before account-approved pairing.
                    val id = runCatching {
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    }.getOrNull()?.trim()?.lowercase(java.util.Locale.ROOT)
                    result.success(
                        if (id != null && id.matches(Regex("[0-9a-f]{16}")) &&
                            id != "0000000000000000" && id != "9774d56d682e549c"
                        ) "$packageName|$id" else null,
                    )
                }
                "getBootAutostart" -> result.success(
                    mapOf(
                        "enabled" to BootAutostart.isEnabled(this),
                        "permissionRequired" to BootAutostart.needsPermission(this),
                    ),
                )
                "setBootAutostart" -> {
                    val enabled = call.arguments as? Boolean
                    if (enabled == null || !isTelevision()) {
                        result.error("bad_args", "TV autostart requires a boolean", null)
                    } else if (BootAutostart.setEnabled(this, enabled)) {
                        result.success(null)
                    } else {
                        result.error("save_failed", "Could not save TV autostart", null)
                    }
                }
                "openBootAutostartPermission" -> {
                    if (!isTelevision()) {
                        result.error("unsupported", "Autostart is only available on TV", null)
                        return@setMethodCallHandler
                    }
                    if (!BootAutostart.needsPermission(this)) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val packageUri = Uri.parse("package:$packageName")
                    // TV firmware varies: try the app-specific permission page,
                    // then the list of apps, then this app's system settings.
                    val settingsIntents = listOf(
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri),
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri),
                    )
                    for (settingsIntent in settingsIntents) {
                        try {
                            startActivity(settingsIntent)
                            result.success(true)
                            return@setMethodCallHandler
                        } catch (_: android.content.ActivityNotFoundException) {
                            // Try the next settings entry point.
                        } catch (_: SecurityException) {
                            // Some TV vendors restrict the app-specific page.
                        }
                    }
                    result.error("unavailable", "Autostart permission settings unavailable", null)
                }
                else -> result.notImplemented()
            }
        }

        // In-app update: launches the system package installer for a
        // downloaded release APK, and the "install unknown apps" settings.
        updatesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/updates",
        )
        updatesChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    try {
                        verifyUpdateApk(apk)
                    } catch (e: SecurityException) {
                        result.error("invalid_update", e.message, null)
                        return@setMethodCallHandler
                    }
                    // minSdk 26 → canRequestPackageInstalls() always applies.
                    if (!packageManager.canRequestPackageInstalls()) {
                        result.success("needs_permission")
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apk,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_ACTIVITY_NEW_TASK,
                            )
                        }
                        startActivity(intent)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                "requestInstallPermission" -> {
                    if (pendingInstallPermissionResult != null) {
                        result.error("settings_active", "Install settings are already open", null)
                        return@setMethodCallHandler
                    }
                    try {
                        pendingInstallPermissionResult = result
                        startActivityForResult(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                            REQUEST_INSTALL_PERMISSION,
                        )
                    } catch (e: Exception) {
                        pendingInstallPermissionResult = null
                        result.error("settings_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DvrCaptureBridge.unregister(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Asks the Dart player route for a freshly resolved live locator and hands
     * the raw reply to [onReply] — `{url, headers}` on success, **null** for
     * every failure shape (no channel yet, no/superseded Dart handler, an
     * unmounted route, a platform error, `notImplemented`). The caller decides
     * the fallback; see [com.gchofficial.iptvs.player.ResolveAgainReply].
     *
     * Exists because [HdrPlayerActivity] is a separate Activity with no Flutter
     * engine of its own: this MethodChannel lives here, and both Activities run
     * on the same process main thread, which is where MethodChannel calls and
     * their replies must happen.
     *
     * The reply is never logged: a Dart-side resolve error message can embed
     * the provider URL, and therefore credentials.
     */
    fun requestFreshLiveLocator(onReply: (Any?) -> Unit) {
        if (!::nativeHdrChannel.isInitialized) {
            onReply(null)
            return
        }
        nativeHdrChannel.invokeMethod(
            "resolveAgain",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = onReply(result)

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                    onReply(null)

                override fun notImplemented() = onReply(null)
            },
        )
    }

    /** Artwork is fetched only by Dart's shared provider gate/cache. No HTTP fallback. */
    fun requestEpisodeArtwork(requestId: String, imageUrl: String, onReply: (String?) -> Unit) {
        if (!::nativeHdrChannel.isInitialized) { onReply(null); return }
        nativeHdrChannel.invokeMethod(
            "loadArtwork",
            mapOf("requestId" to requestId, "url" to imageUrl),
            object : MethodChannel.Result {
                override fun success(result: Any?) = onReply(result as? String)
                override fun error(code: String, message: String?, details: Any?) = onReply(null)
                override fun notImplemented() = onReply(null)
            },
        )
    }

    fun cancelEpisodeArtwork(requestId: String) {
        runOnUiThread {
            if (::nativeHdrChannel.isInitialized) {
                nativeHdrChannel.invokeMethod("cancelArtwork", mapOf("requestId" to requestId))
            }
        }
    }

    /**
     * Relays a short, credential-free note from [HdrPlayerActivity] into Dart's
     * exportable diagnostics log (`playback` scope).
     *
     * The seamless preview→fullscreen handoff either adopts the shared engine or
     * silently reloads the stream, and until now that outcome existed only in
     * logcat — unreachable for a user reporting "it reconnects when I go
     * fullscreen" from a TV. Dart already logs which handoff it *asked* for
     * (`fullscreen open decision=…`); this is the other half, what the Activity
     * actually did. Fire-and-forget: a missing channel or handler is not worth
     * reacting to.
     *
     * **Never pass anything derived from a URL, header or provider reply** —
     * this text is exported verbatim.
     */
    /**
     * Inbound half of the zap wire contract: one member of the shared command
     * vocabulary (`lib/player/zap_command.dart`), sent by
     * [HdrPlayerActivity]'s key policy.
     *
     * Fire-and-forget by design — the native side names a *command*, never a
     * channel, and holds no cursor to reconcile against a reply.
     */
    fun requestZap(command: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeZap", mapOf("command" to command))
    }

    fun requestPlaybackSettings(state: Map<String, Any>, onReply: (Any?) -> Unit) {
        if (!::nativeHdrChannel.isInitialized) { onReply(null); return }
        nativeHdrChannel.invokeMethod("getPlaybackSettings", state, object : MethodChannel.Result {
            override fun success(result: Any?) = onReply(result)
            override fun error(code: String, message: String?, details: Any?) = onReply(null)
            override fun notImplemented() = onReply(null)
        })
    }

    fun selectPlaybackSetting(command: String) {
        if (::nativeHdrChannel.isInitialized) nativeHdrChannel.invokeMethod("nativeControl", command)
    }

    fun reportDvr(method: String, args: Map<String, Any>) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod(method, args)
    }

    fun reportNativeFirstFrame(openId: Long) {
        if (::nativeHdrChannel.isInitialized) {
            nativeHdrChannel.invokeMethod("nativePlayback", mapOf("event" to "firstFrame", "nativeOpenId" to openId))
        }
    }

    fun reportNativePlaybackProgress(openId: Long, positionMs: Long, durationMs: Long, flush: Boolean) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativePlayback", mapOf(
            "event" to "progress",
            "nativeOpenId" to openId,
            "positionMs" to positionMs,
            "durationMs" to durationMs,
            "flush" to flush,
        ))
    }

    fun logPlaybackDiagnostic(note: String, providerRejection: ProviderRejection? = null, playbackId: Long? = null) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeDiagnostic", buildMap {
            put("note", note)
            if (providerRejection != null) {
                put("providerStatus", providerRejection.httpStatus)
                putAll(providerRejection.eventFields())
                playbackId?.let { put("playbackId", it) }
            }
        })
    }

    /**
     * Fails closed unless [apk] is a cache-owned APK for this exact application
     * and is signed by the same certificate as the installed build. Dart has
     * already verified the signed release-manifest digest; this native check
     * prevents a wrong-package or wrong-signer APK reaching Package Installer.
     */
    @Suppress("DEPRECATION")
    private fun verifyUpdateApk(apk: File) {
        val cachePath = cacheDir.canonicalFile.toPath()
        val apkPath = apk.canonicalFile.toPath()
        if (!apk.isFile || !apkPath.startsWith(cachePath)) {
            throw SecurityException("Update APK is outside the application cache")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apkPath.toString(), flags)
            ?: throw SecurityException("Update APK package metadata is unreadable")
        if (candidate.packageName != packageName) {
            throw SecurityException("Update APK package identity does not match")
        }
        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidateSigners = signerDigests(candidate)
        val installedSigners = signerDigests(installed)
        if (candidateSigners.isEmpty() || candidateSigners != installedSigners) {
            throw SecurityException("Update APK signing certificate does not match")
        }
    }

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            info.signatures ?: emptyArray()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(separator = "") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_PERMISSION) {
            pendingInstallPermissionResult?.success(packageManager.canRequestPackageInstalls())
            pendingInstallPermissionResult = null
            return
        }
        if (requestCode == REQUEST_NATIVE_PLAYER && ::nativeHdrChannel.isInitialized) {
            // Relay the final VOD position (see HdrPlayerActivity.finish) so the
            // Dart side can persist the resume point, plus the final favorite
            // state so the channel list reflects an in-player toggle on return.
            // Null args = live with no favorite change / legacy.
            val positionMs = data?.getLongExtra(HdrPlayerActivity.RESULT_POSITION_MS, -1L) ?: -1L
            val durationMs = data?.getLongExtra(HdrPlayerActivity.RESULT_DURATION_MS, -1L) ?: -1L
            val map = buildMap<String, Any> {
                if (data?.getBooleanExtra(HdrPlayerActivity.RESULT_INACTIVITY_RESET, false) == true) {
                    put("inactivityReset", true)
                }
                data?.takeIf { it.hasExtra("nativeOpenId") }?.let {
                    put("nativeOpenId", it.getLongExtra("nativeOpenId", 0L))
                }
                if (positionMs >= 0L && durationMs > 0L) {
                    put("positionMs", positionMs)
                    put("durationMs", durationMs)
                }
                data?.takeIf { it.hasExtra(HdrPlayerActivity.RESULT_FAVORITE) }?.let { result ->
                    put("favorite", result.getBooleanExtra(HdrPlayerActivity.RESULT_FAVORITE, false))
                }
                data?.getStringExtra(HdrPlayerActivity.RESULT_ASPECT)?.let {
                    put("aspect", it)
                }
                data?.getStringExtra(HdrPlayerActivity.RESULT_SELECTED_EPISODE_ID)?.let {
                    put("selectedEpisodeId", it)
                }
            }
            nativeHdrChannel.invokeMethod("nativeClosed", if (map.isEmpty()) null else map)
        }
    }

    companion object {
        /**
         * Set while a MainActivity exists. Lets [HdrPlayerActivity] move the
         * *main* task behind its PiP window (once an Activity enters PiP it lives
         * in its own pinned task, so it can't move this one from there).
         */
        var instance: WeakReference<MainActivity>? = null
            private set

        // Keep large episode metadata off Binder while allowing a retained
        // Intent to restore the same cards after Activity or process recreation.
        internal fun holdEpisodeMetadata(context: Context, json: String): String {
            val token = UUID.randomUUID().toString()
            val file = episodeMetadataFile(context, token)!!
            try {
                file.writeText(json)
            } catch (error: Exception) {
                runCatching { file.delete() }
                throw error
            }
            return token
        }
        fun readEpisodeMetadata(context: Context, token: String?): String? = runCatching {
            episodeMetadataFile(context, token)?.readText()
        }.getOrNull()
        fun releaseEpisodeMetadata(context: Context, token: String?) {
            runCatching { episodeMetadataFile(context, token)?.delete() }
        }
        private fun episodeMetadataFile(context: Context, token: String?): File? {
            if (token == null || runCatching { UUID.fromString(token).toString() }.getOrNull() != token) return null
            return File(context.cacheDir, "player-episodes-$token.json")
        }

        private const val REQUEST_NATIVE_PLAYER = 4120
        private const val REQUEST_INSTALL_PERMISSION = 4121
    }
}
