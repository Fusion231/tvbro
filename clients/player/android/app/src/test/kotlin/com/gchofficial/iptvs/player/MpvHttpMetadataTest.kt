package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvHttpMetadataTest {
    @Test
    fun `stock wrapper without synchronous capability never enables trace`() {
        assertEquals("all=warn", MpvHttpMetadata.logLevel(false))
        assertTrue(MpvHttpMetadata.logLevel(true).contains("ffmpeg=trace"))
        assertTrue(MpvHttpMetadata.logLevel(true).contains("ffmpeg/demuxer=warn"))
    }

    @Test
    fun `private adapter preserves retry and final origin without paths or credentials`() {
        val value = MpvHttpMetadata.rejection("status=429;retry-after=120;response-origin=https://cdn.example:8443/", "https://provider.example/private")!!
        assertEquals(429, value.httpStatus)
        assertEquals("120", value.retryAfter)
        assertEquals("https://cdn.example:8443/", value.responseOrigin)
        assertFalse(value.eventFields().toString().contains("private"))
        assertEquals("Wed, 21 Oct 2026 07:28:00 GMT", MpvHttpMetadata.rejection("status=503;retry-after=Wed, 21 Oct 2026 07:28:00 GMT", null)!!.retryAfter)
    }

    @Test
    fun `healthy responses invalid timing and arbitrary trace do not escape`() {
        assertNull(MpvHttpMetadata.rejection("status=200;retry-after=120", null))
        assertNull(MpvHttpMetadata.rejection("status=503;retry-after=secret-provider-token", null))
        assertNull(MpvHttpMetadata.rejection("Authorization: Bearer secret", null))
        assertNull(MpvHttpMetadata.rejection("status=429\nAuthorization: secret", null))
        assertNull(MpvHttpMetadata.rejection("ready=1", null))
    }
}
