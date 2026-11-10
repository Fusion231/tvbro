package com.gchofficial.iptvs.player

import java.util.Locale

/** Unknown and Dolby Vision tracks keep the colour-correct software path. */
object MpvDecodePolicy {
    private val knownVideoMimeTypes = setOf(
        "video/avc", "video/hevc", "video/av01", "video/x-vnd.on2.vp8",
        "video/x-vnd.on2.vp9", "video/mpeg2", "video/mp4v-es", "video/3gpp",
        "video/wvc1", "video/mpeg",
    )

    fun hardwareDecodeAllowed(mimeType: String?, codecs: String?): Boolean {
        val mime = mimeType?.lowercase(Locale.ROOT) ?: return false
        val codecNames = codecs?.lowercase(Locale.ROOT).orEmpty()
        return mime in knownVideoMimeTypes &&
            !codecNames.contains("dvhe") &&
            !codecNames.contains("dvh1") &&
            !codecNames.contains("dvav") &&
            !codecNames.contains("dva1") &&
            !codecNames.contains("dav1")
    }
}

/** Exo's format evidence belongs to the first locator, never to a later zap. */
class MpvLoadDecodePolicy(allowHardwareForFirstLoad: Boolean) {
    private var hardwarePending = allowHardwareForFirstLoad

    fun nextHwdec(): String {
        val hardware = hardwarePending
        hardwarePending = false
        return if (hardware) "mediacodec-copy" else "no"
    }
}
