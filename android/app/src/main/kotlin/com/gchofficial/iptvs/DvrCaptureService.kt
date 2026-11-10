package com.gchofficial.iptvs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.gchofficial.iptvs.player.isTelevisionDevice

/** Keeps manual Dart DVR capture protected while the user leaves the player. */
class DvrCaptureService : Service() {
    companion object {
        const val ACTION_START = "com.gchofficial.iptvs.dvr.START"
        const val ACTION_STOP = "com.gchofficial.iptvs.dvr.STOP"
        const val ACTION_NOTIFICATION_STOP = "com.gchofficial.iptvs.dvr.NOTIFICATION_STOP"
        const val EXTRA_ID = "recording_id"
        const val EXTRA_NOTIFICATION_VISIBLE = "notification_visible"

        private const val NOTIFICATION_CHANNEL_ID = "tvbro_dvr_recording"
        private const val NOTIFICATION_ID = 8401
        private const val USER_STOP_ACK_MS = 5_000L
        private const val SYSTEM_TIMEOUT_ACK_MS = 1_800L

        @Volatile private var activeService: DvrCaptureService? = null

        fun isActiveFor(id: String): Boolean = activeService?.recordingId == id

        fun hasActiveRecording(): Boolean = activeService?.recordingId != null

        fun notificationVisibleFor(id: String): Boolean =
            activeService?.takeIf { it.recordingId == id }?.notificationVisible == true

        fun stopActive() {
            val service = activeService ?: return
            service.recordingId?.let(service::stopForId)
        }

        fun stopForId(id: String) {
            activeService?.stopForId(id)
        }
    }

    private var recordingId: String? = null
    private var notificationVisible = true
    private var wakeLock: PowerManager.WakeLock? = null
    private var expectedStop = false
    private var stopRequestPending = false

    override fun onCreate() {
        super.onCreate()
        activeService = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecordingProtection(intent, startId)
            ACTION_STOP -> {
                val id = intent.getStringExtra(EXTRA_ID)
                if (id != null) stopForId(id)
                else stopSelf(startId)
            }
            ACTION_NOTIFICATION_STOP -> {
                val id = intent.getStringExtra(EXTRA_ID)
                if (id != null && id == recordingId) {
                    requestDartStop(id, "notification", USER_STOP_ACK_MS)
                } else {
                    stopSelf(startId)
                }
            }
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startRecordingProtection(intent: Intent, startId: Int) {
        val id = intent.getStringExtra(EXTRA_ID)?.takeIf(String::isNotBlank)
        if (id == null) {
            DvrCaptureBridge.foregroundStartFailed(id.orEmpty())
            stopSelf(startId)
            return
        }
        if (recordingId != null && recordingId != id) {
            DvrCaptureBridge.foregroundStartFailed(id)
            stopSelf(startId)
            return
        }

        recordingId = id
        notificationVisible = intent.getBooleanExtra(EXTRA_NOTIFICATION_VISIBLE, false)
        expectedStop = false
        stopRequestPending = false
        try {
            val notification = buildNotification(id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, foregroundServiceType())
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "TVBro:DvrCapture",
            ).also { it.acquire() }
            DvrCaptureBridge.foregroundStarted(id)
        } catch (_: Exception) {
            expectedStop = true
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            DvrCaptureBridge.foregroundStartFailed(id)
            stopSelf(startId)
        }
    }

    private fun foregroundServiceType(): Int {
        return if (isTelevisionDevice(this)) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        }
    }

    private fun buildNotification(id: String): Notification {
        val stopIntent = Intent(this, DvrCaptureService::class.java)
            .setAction(ACTION_NOTIFICATION_STOP)
            .putExtra(EXTRA_ID, id)
        val stopPendingIntent = PendingIntent.getService(
            this,
            id.hashCode(),
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentPendingIntent = openIntent?.let {
            PendingIntent.getActivity(
                this,
                NOTIFICATION_ID,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val hasBackgroundTimeLimit =
            !isTelevisionDevice(this) &&
                Build.VERSION.SDK_INT >= 35 &&
                applicationInfo.targetSdkVersion >= 35
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Recording live TV")
            .setSubText(
                if (hasBackgroundTimeLimit) {
                    "Android may stop after 6 background hours"
                } else {
                    "Live TV"
                },
            )
            .setContentIntent(contentPendingIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_media_pause,
                    "Stop",
                    stopPendingIntent,
                ).build(),
            )
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Recording",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows active recording status and a stop control."
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun requestDartStop(id: String, reason: String, timeoutMs: Long) {
        if (stopRequestPending) return
        stopRequestPending = true
        expectedStop = true
        DvrCaptureBridge.requestStop(id, reason, timeoutMs) { stopForId(id) }
    }

    private fun stopForId(id: String) {
        if (recordingId != id) return
        expectedStop = true
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        recordingId = null
        stopSelf()
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        if (lock.isHeld) lock.release()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        super.onTimeout(startId, fgsType)
        val id = recordingId
        if (id == null) {
            stopSelf(startId)
        } else {
            requestDartStop(id, "timeout", SYSTEM_TIMEOUT_ACK_MS)
        }
    }

    override fun onDestroy() {
        releaseWakeLock()
        DvrCaptureBridge.serviceDestroyed(recordingId, expectedStop)
        activeService = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
