package com.gchofficial.iptvs.player

/** Only the reviewed JNI adapter may opt this client into private HTTP trace. */
object MpvHttpMetadata {
    const val PREFIX = "tvbro/http-response"
    const val READY = "ready=1"
    const val READY_TYPED_HEADERS = "ready=2"
    const val SAFE_LOG_LEVEL = "all=warn"
    private const val PRIVATE_LOG_LEVEL =
        "all=warn,ffmpeg=trace,ffmpeg/audio=warn,ffmpeg/video=warn,ffmpeg/demuxer=warn"

    fun logLevel(privateAdapterReady: Boolean): String =
        if (privateAdapterReady) PRIVATE_LOG_LEVEL else SAFE_LOG_LEVEL

    fun rejection(payload: String, fallbackUrl: String?): ProviderRejection? {
        if (payload.length > 512 || payload.any { it == '\r' || it == '\n' || it == '\u0000' }) return null
        val fields = payload.split(';').mapNotNull { entry ->
            val split = entry.indexOf('=')
            if (split <= 0) null else entry.substring(0, split).trim() to entry.substring(split + 1).trim()
        }.toMap()
        val status = fields["status"]?.toIntOrNull() ?: return null
        val retryAfter = fields["retry-after"]?.takeIf { it.length <= 128 }
        return ProviderRejection.fromResponse(status,
            retryAfter?.let { mapOf("Retry-After" to listOf(it)) } ?: emptyMap(),
            fields["response-origin"] ?: fallbackUrl)
    }
}
