package com.gchofficial.iptvs.player

import android.app.Activity
import android.os.Build

/** Window-scoped request; restore the original preference on exit/background. */
class RefreshRateMatcher(private val activity: Activity) {
    private val originalMode = activity.window.attributes.preferredDisplayModeId
    private var lastFps = 0f

    fun apply(enabled: Boolean, fps: Float) {
        if (!enabled) { restore(); return }
        if (fps == lastFps || !fps.isFinite() || fps <= 0f) return
        lastFps = fps
        @Suppress("DEPRECATION")
        val display = if (Build.VERSION.SDK_INT >= 30) activity.display
            else activity.windowManager.defaultDisplay
        display ?: return
        val current = display.mode
        val modes = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
        val rate = matchingRefreshRate(fps, modes.map { it.refreshRate }, current.refreshRate)
            ?: return
        val chosen = modes.firstOrNull { it.refreshRate == rate } ?: return
        if (activity.window.attributes.preferredDisplayModeId == chosen.modeId) return
        activity.window.attributes = activity.window.attributes.apply {
            preferredDisplayModeId = chosen.modeId
        }
    }

    fun restore() {
        lastFps = 0f
        if (activity.window.attributes.preferredDisplayModeId == originalMode) return
        activity.window.attributes = activity.window.attributes.apply {
            preferredDisplayModeId = originalMode
        }
    }
}
