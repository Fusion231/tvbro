package com.gchofficial.iptvs.player

import io.flutter.embedding.engine.FlutterShellArgs

@Suppress("DEPRECATION")
internal fun FlutterShellArgs.applyFlutterRendererCompatibility(
    manufacturer: String,
    model: String,
    socModel: String?,
) {
    val tclG10 = manufacturer.trim().equals("TCL", ignoreCase = true) &&
        model.trim().equals("G10", ignoreCase = true)
    if (tclG10 || socModel?.trim().equals("RTD2875P", ignoreCase = true)) {
        // Skia avoids the Impeller paths implicated in these PowerVR TV crashes.
        remove(FlutterShellArgs.ARG_ENABLE_IMPELLER)
        add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
    }
}
