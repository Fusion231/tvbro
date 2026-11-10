package com.gchofficial.iptvs

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

/** MethodChannel bridge between the Dart capture owner and Android's FGS. */
internal object DvrCaptureBridge {
    private const val CHANNEL_NAME = "tvbro/dvr_capture"
    private const val START_ACK_ERROR = "dvr_capture_start_failed"
    private const val NOTIFICATION_PERMISSION_REQUEST = 8402
    private const val START_ACK_TIMEOUT_MS = 7_000L
    private const val PERMISSION_PREFS = "dvr_capture_permission"
    private const val PERMISSION_REQUESTED_KEY = "notification_requested"

    private data class PendingStart(
        val id: String,
        val result: MethodChannel.Result,
        var notificationVisible: Boolean,
        var timeout: Runnable? = null,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var channel: MethodChannel? = null
    @Volatile private var appContext: Context? = null
    @Volatile private var foregroundActivity: WeakReference<Activity>? = null
    @Volatile private var registeredEngine: FlutterEngine? = null
    private var pendingStart: PendingStart? = null

    fun register(context: Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        foregroundActivity = (context as? Activity)?.let(::WeakReference)
        registeredEngine = engine
        val methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "start" -> {
                    val id = args?.get("id") as? String
                    if (id.isNullOrBlank()) {
                        result.error("bad_args", "Missing recording identity.", null)
                    } else {
                        start(context.applicationContext, id, result)
                    }
                }
                "stop" -> {
                    val id = args?.get("id") as? String
                    if (id.isNullOrBlank()) {
                        result.error("bad_args", "Missing recording identity.", null)
                    } else {
                        cancelPendingStart(id)
                        DvrCaptureService.stopForId(id)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Release service protection when the Flutter host permanently detaches. */
    fun unregister(engine: FlutterEngine) {
        if (registeredEngine !== engine) return
        pendingStart?.let { cancelPendingStart(it.id) }
        channel?.setMethodCallHandler(null)
        channel = null
        foregroundActivity = null
        appContext = null
        registeredEngine = null
        DvrCaptureService.stopActive()
    }

    /** Called by foreground playback Activities so permission UI uses the visible Activity. */
    fun setForegroundActivity(value: Activity) {
        if (!value.isFinishing && !value.isDestroyed) {
            foregroundActivity = WeakReference(value)
        }
    }

    fun clearForegroundActivity(value: Activity) {
        if (foregroundActivity?.get() === value) foregroundActivity = null
    }

    private fun start(
        context: Context,
        id: String,
        result: MethodChannel.Result,
    ) {
        if (DvrCaptureService.isActiveFor(id)) {
            result.success(
                mapOf("notificationVisible" to DvrCaptureService.notificationVisibleFor(id)),
            )
            return
        }
        if (DvrCaptureService.hasActiveRecording() || pendingStart != null) {
            result.error(START_ACK_ERROR, "Another recording is already active.", null)
            return
        }

        val notificationVisible = notificationPermissionGranted(context)
        val pending = PendingStart(id, result, notificationVisible)
        pendingStart = pending
        if (!notificationVisible && shouldAskForNotificationPermission(context)) {
            val currentActivity = foregroundActivity?.get()?.takeIf {
                !it.isFinishing && !it.isDestroyed
            }
            if (currentActivity != null) {
                context.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PERMISSION_REQUESTED_KEY, true)
                    .apply()
                try {
                    currentActivity.requestPermissions(
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        NOTIFICATION_PERMISSION_REQUEST,
                    )
                    return
                } catch (_: Exception) {
                    // Recording still works with the in-app Stop control. The
                    // user can grant notification access later in Android settings.
                }
            }
        }
        startService(context, pending)
    }

    private fun notificationPermissionGranted(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    private fun shouldAskForNotificationPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !context.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE)
                .getBoolean(PERMISSION_REQUESTED_KEY, false)

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val pending = pendingStart ?: return
        pending.notificationVisible =
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        val context = appContext
        if (context == null) {
            finishStartFailure(pending.id)
            return
        }
        startService(context, pending)
    }

    private fun startService(context: Context, pending: PendingStart) {
        pendingStart = pending
        val id = pending.id
        val intent = Intent(context, DvrCaptureService::class.java)
            .setAction(DvrCaptureService.ACTION_START)
            .putExtra(DvrCaptureService.EXTRA_ID, id)
            .putExtra(DvrCaptureService.EXTRA_NOTIFICATION_VISIBLE, pending.notificationVisible)
        val timeout = Runnable {
            finishStartFailure(id)
            DvrCaptureService.stopForId(id)
        }
        pending.timeout = timeout
        mainHandler.postDelayed(timeout, START_ACK_TIMEOUT_MS)
        try {
            context.startForegroundService(intent)
        } catch (_: Exception) {
            finishStartFailure(id)
            DvrCaptureService.stopForId(id)
        }
    }

    fun foregroundStarted(id: String) {
        val pending = pendingStart
        if (pending?.id != id) {
            DvrCaptureService.stopForId(id)
            return
        }
        pending.timeout?.let(mainHandler::removeCallbacks)
        pendingStart = null
        pending.result.success(mapOf("notificationVisible" to pending.notificationVisible))
    }

    fun foregroundStartFailed(id: String) {
        if (id.isBlank()) {
            pendingStart?.let { finishStartFailure(it.id) }
        } else {
            finishStartFailure(id)
        }
    }

    private fun finishStartFailure(id: String) {
        val pending = pendingStart
        if (pending?.id != id) return
        pending.timeout?.let(mainHandler::removeCallbacks)
        pendingStart = null
        pending.result.error(
            START_ACK_ERROR,
            "Android could not keep the recording running.",
            null,
        )
    }

    /**
     * Dart calls stop after its bounded start wait expires. Clear an outstanding
     * permission prompt before it can later start protection for a closed Dart
     * recording; if foreground startup already began, stop that service too.
     */
    private fun cancelPendingStart(id: String) {
        val pending = pendingStart?.takeIf { it.id == id } ?: return
        pending.timeout?.let(mainHandler::removeCallbacks)
        pendingStart = null
        pending.result.error(
            START_ACK_ERROR,
            "Recording start was cancelled.",
            null,
        )
    }

    fun serviceDestroyed(recordingId: String?, expectedStop: Boolean) {
        if (recordingId == null) {
            val pending = pendingStart ?: return
            finishStartFailure(pending.id)
        } else if (!expectedStop) {
            protectionLost(recordingId, "Android recording protection stopped unexpectedly.")
        }
    }

    /** Ask Dart to finish its file before removing the foreground protection. */
    fun requestStop(
        id: String,
        reason: String,
        timeoutMs: Long,
        onFinished: () -> Unit,
    ) {
        val methodChannel = channel
        if (methodChannel == null) {
            onFinished()
            return
        }

        val completed = AtomicBoolean(false)
        fun finishOnce() {
            if (completed.compareAndSet(false, true)) onFinished()
        }
        mainHandler.postDelayed({ finishOnce() }, timeoutMs)
        try {
            methodChannel.invokeMethod(
                "stopRequested",
                mapOf("id" to id, "reason" to reason),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = finishOnce()
                    override fun error(code: String, message: String?, details: Any?) =
                        finishOnce()
                    override fun notImplemented() = finishOnce()
                },
            )
        } catch (_: Exception) {
            finishOnce()
        }
    }

    fun protectionLost(id: String, error: String) {
        try {
            channel?.invokeMethod(
                "protectionLost",
                mapOf("id" to id, "error" to error),
            )
        } catch (_: Exception) {
            // The Flutter engine may already be detached. The service still
            // tears down below, and the next app launch recovers the file as
            // interrupted from its manifest.
        }
    }
}
