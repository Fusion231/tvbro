package com.gchofficial.iptvs

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.gchofficial.iptvs.player.isTelevisionDevice

/** Device-local setting, also readable before Flutter starts at boot. */
internal object BootAutostart {
    private fun preferences(context: Context) =
        context.getSharedPreferences("tvbro_startup", Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean =
        preferences(context).getBoolean("launch_on_boot", true)

    fun setEnabled(context: Context, enabled: Boolean): Boolean =
        preferences(context).edit().putBoolean("launch_on_boot", enabled).commit()

    // A user-granted overlay permission allows background activity starts on
    // Android 10+. We use that exemption at boot without creating an overlay.
    fun needsPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !Settings.canDrawOverlays(context)
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED ||
            !isTelevisionDevice(context) ||
            !BootAutostart.isEnabled(context) ||
            BootAutostart.needsPermission(context)
        ) return

        // Match the TV launcher's category so reopening cannot add a second
        // Flutter Activity above an existing native player.
        val launch = context.packageManager.getLeanbackLaunchIntentForPackage(context.packageName)
            ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        try {
            context.startActivity(launch)
        } catch (error: RuntimeException) {
            Log.w("TVBroBoot", "Device did not allow launch at boot", error)
        }
    }
}
