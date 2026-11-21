package com.gchofficial.iptvs.player

import io.flutter.embedding.engine.FlutterShellArgs
import org.junit.Assert.assertEquals
import org.junit.Test

@Suppress("DEPRECATION")
class FlutterRendererCompatibilityTest {
    @Test
    fun `TCL G10 and Realtek RTD2875P select Skia before the engine starts`() {
        for ((manufacturer, model, soc) in listOf(
            Triple("TCL", "G10", null),
            Triple("TCL", "G10", "RTD6748"),
            Triple("TCL", "Other model", " rtd2875p "),
        )) {
            val args = FlutterShellArgs(arrayOf(FlutterShellArgs.ARG_ENABLE_IMPELLER, "--trace-startup"))

            args.applyFlutterRendererCompatibility(manufacturer, model, soc)

            assertEquals(setOf(FlutterShellArgs.ARG_DISABLE_IMPELLER, "--trace-startup"), args.toArray().toSet())
        }
    }

    @Test
    fun `similar model names and other chipsets keep their renderer arguments`() {
        for ((manufacturer, model, soc) in listOf(
            Triple("TCL", "G10 Pro", "RTD2875"),
            Triple("Other", "G10", "RTD2873"),
            Triple("Xiaomi", "MiTV", null),
        )) {
            val args = FlutterShellArgs(arrayOf(FlutterShellArgs.ARG_ENABLE_IMPELLER))

            args.applyFlutterRendererCompatibility(manufacturer, model, soc)

            assertEquals(setOf(FlutterShellArgs.ARG_ENABLE_IMPELLER), args.toArray().toSet())
        }
    }
}
