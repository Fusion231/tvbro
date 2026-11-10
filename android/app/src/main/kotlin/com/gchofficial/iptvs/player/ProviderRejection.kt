package com.gchofficial.iptvs.player

import java.net.URI
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/** Only the response origin may leave the HTTP source: stream paths can contain credentials. */
class ProviderRejection private constructor(
    val httpStatus: Int,
    val retryAfter: String?,
    val responseOrigin: String?,
) {
    fun eventFields(): Map<String, Any> = buildMap {
        put("httpStatus", httpStatus)
        retryAfter?.let { put("retryAfter", it) }
        responseOrigin?.let { put("responseOrigin", it) }
    }

    override fun toString(): String = "HTTP $httpStatus"

    companion object {
        private val httpLogStatus = Regex(
            "(?:\\bHTTP(?:/\\d(?:\\.\\d)?)?\\s*(?:error\\s*)?|\\bstatus(?:\\s+code)?\\s*[:=]?\\s*|\\bserver returned\\s+)(401|403|429|503)\\b",
            RegexOption.IGNORE_CASE,
        )

        fun fromLog(message: String, responseUrl: String?): ProviderRejection? {
            val status = httpLogStatus.find(message)?.groupValues?.get(1)?.toIntOrNull() ?: return null
            // Preserve response headers if a transport supplied them; never probe.
            val retryAfter = Regex("(?im)^\\s*Retry-After\\s*:\\s*([^\\r\\n]+)")
                .find(message)?.groupValues?.get(1)
            return fromResponse(status, retryAfter?.let { mapOf("Retry-After" to listOf(it)) } ?: emptyMap(), responseUrl)
        }

        fun fromResponse(
            status: Int,
            headers: Map<String, List<String>>,
            responseUrl: String?,
        ): ProviderRejection? {
            val retryAfter = headers.entries
                .firstOrNull { it.key.equals("Retry-After", ignoreCase = true) }
                ?.value?.firstOrNull()?.trim()?.takeIf { value ->
                    (value.isNotEmpty() && value.all { it in '0'..'9' } && value.toLongOrNull() != null) ||
                        runCatching { ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME) }.isSuccess
                }
            if (!isProviderRejectionStatus(status) && !(status == 503 && retryAfter != null)) return null
            val origin = responseUrl?.let { value ->
                runCatching {
                    val uri = URI(value)
                    if (uri.scheme?.lowercase() !in listOf("http", "https") || uri.host.isNullOrEmpty()) {
                        null
                    } else {
                        URI(uri.scheme.lowercase(), null, uri.host, uri.port, "/", null, null).toString()
                    }
                }.getOrNull()
            }
            return ProviderRejection(status, retryAfter, origin)
        }
    }
}
