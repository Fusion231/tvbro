package com.gchofficial.iptvs

import android.content.Context
import android.os.SystemClock
import android.provider.Settings

/** Main-thread lifecycle bridge. Only small session markers survive process death. */
internal object AppSession {
    const val EXTRA_GENERATION = "appSessionGeneration"
    private const val PREFERENCES = "app-session"
    private var policy: AppInactivityPolicy? = null

    private fun policy(context: Context): AppInactivityPolicy = policy ?: run {
        val saved = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        AppInactivityPolicy(AppInactivityPolicy.Snapshot(
            backgroundAtMs = if (saved.contains("backgroundAtMs")) saved.getLong("backgroundAtMs", 0L) else null,
            bootCount = saved.getInt("bootCount", -1),
            resetPending = saved.getBoolean("resetPending", false),
            generation = saved.getLong("generation", 0L),
        )).also { policy = it }
    }

    private fun bootCount(context: Context): Int =
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)

    private fun save(context: Context, current: AppInactivityPolicy) {
        val state = current.snapshot
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().apply {
            state.backgroundAtMs?.let { putLong("backgroundAtMs", it) } ?: remove("backgroundAtMs")
            putInt("bootCount", state.bootCount)
            putBoolean("resetPending", state.resetPending)
            putLong("generation", state.generation)
        }.apply()
    }

    fun activityStarted(context: Context, owner: Any): Boolean {
        val current = policy(context)
        current.activityStarted(owner, SystemClock.elapsedRealtime(), bootCount(context))
        save(context, current)
        return current.snapshot.resetPending
    }

    fun activityStopped(context: Context, owner: Any, changingConfiguration: Boolean) {
        val current = policy(context)
        current.activityStopped(owner, SystemClock.elapsedRealtime(), bootCount(context), changingConfiguration)
        save(context, current)
    }

    fun pictureInPictureChanged(context: Context, owner: Any, shown: Boolean) {
        val current = policy(context)
        current.pictureInPictureChanged(owner, shown, SystemClock.elapsedRealtime(), bootCount(context))
        save(context, current)
    }

    fun activityDestroyed(context: Context, owner: Any, changingConfiguration: Boolean) {
        val current = policy(context)
        current.activityDestroyed(owner, SystemClock.elapsedRealtime(), bootCount(context), changingConfiguration)
        save(context, current)
    }

    fun resetPending(context: Context): Boolean {
        val current = policy(context)
        val pending = current.checkExpiry(SystemClock.elapsedRealtime(), bootCount(context))
        save(context, current)
        return pending
    }

    fun generation(context: Context): Long = policy(context).snapshot.generation

    fun shouldClosePlayer(context: Context, playerGeneration: Long): Boolean =
        resetPending(context) || playerGeneration != generation(context)

    fun consumeReset(context: Context): Boolean {
        val current = policy(context)
        current.checkExpiry(SystemClock.elapsedRealtime(), bootCount(context))
        val pending = current.consumeReset()
        save(context, current)
        return pending
    }
}
