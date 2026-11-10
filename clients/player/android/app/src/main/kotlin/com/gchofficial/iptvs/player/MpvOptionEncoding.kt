package com.gchofficial.iptvs.player

/**
 * Pure formatting for mpv header items, kept
 * free of Android/JNI imports so it's covered by a plain-JUnit test rather
 * than an instrumented one — see [ReconnectPolicy] for the same pattern.
 *
 * The private JNI property decodes an ASCII envelope into MPV_FORMAT_NODE_ARRAY.
 * Lengths count UTF-8 bytes; hex avoids JNI modified-UTF-8 conversions and mpv's
 * string-list escaping, including commas and literal trailing backslashes.
 */
object MpvOptionEncoding {
    const val PRIVATE_HEADERS = "tvbro/http-request-headers"

    fun headerFields(headers: List<Pair<String, String>>): List<String> =
        headers.map { (key, value) -> "$key: $value" }

    fun privateHeaders(fields: List<String>): String {
        require(fields.size <= 128)
        val result = buildString {
            append("v1;").append(fields.size).append(';')
            for (field in fields) {
                require(field.none { it == '\r' || it == '\n' || it == '\u0000' })
                val bytes = field.toByteArray(Charsets.UTF_8)
                require(bytes.size <= 8192)
                append(bytes.size).append(':')
                for (byte in bytes) {
                    val value = byte.toInt() and 255
                    append("0123456789abcdef"[value ushr 4])
                    append("0123456789abcdef"[value and 15])
                }
            }
        }
        require(result.length <= 65536)
        return result
    }
}
