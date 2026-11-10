package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Test

class MpvOptionEncodingTest {
    @Test
    fun `authorization is an HTTP header name not a suboption length prefix`() {
        assertEquals(listOf("Authorization: Bearer synthetic-token", "X-Audit: synthetic-only"),
            MpvOptionEncoding.headerFields(listOf("Authorization" to "Bearer synthetic-token", "X-Audit" to "synthetic-only")))
    }

    @Test
    fun `header items keep commas and backslashes verbatim`() {
        assertEquals(listOf("Cookie: a=one, b=two", "X-Path: a\\b"),
            MpvOptionEncoding.headerFields(listOf("Cookie" to "a=one, b=two", "X-Path" to "a\\b")))
    }

    @Test
    fun `private envelope counts UTF8 bytes and retains exact literal items`() {
        val fields = listOf("Cookie: a=one, b=two", "X-Path: a\\b\\", "X-Name: ż😀")
        val encoded = MpvOptionEncoding.privateHeaders(fields)
        assertEquals("v1;0;", MpvOptionEncoding.privateHeaders(emptyList()))
        assertEquals(true, encoded.all { it.code < 128 })
        var cursor = encoded.indexOf(';', 3) + 1
        val decoded = fields.map {
            val colon = encoded.indexOf(':', cursor)
            val size = encoded.substring(cursor, colon).toInt()
            cursor = colon + 1
            val bytes = ByteArray(size) { index -> encoded.substring(cursor + index * 2, cursor + index * 2 + 2).toInt(16).toByte() }
            cursor += size * 2
            String(bytes, Charsets.UTF_8)
        }
        assertEquals(fields, decoded)
        assertEquals(encoded.length, cursor)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `private envelope rejects header injection`() {
        MpvOptionEncoding.privateHeaders(listOf("Authorization: value\r\nX-Injected: yes"))
    }

    @Test
    fun `unicode and literal percent remain ordinary header values`() {
        assertEquals(listOf("X-Name: żółć", "X-Value: %10%literal"),
            MpvOptionEncoding.headerFields(listOf("X-Name" to "żółć", "X-Value" to "%10%literal")))
        assertEquals(emptyList<String>(), MpvOptionEncoding.headerFields(emptyList()))
    }
}
