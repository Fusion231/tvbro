package com.gchofficial.iptvs.player

import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URL
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ProviderRejectionTest {
    @Test
    fun `retry timing in available transport error headers is preserved without a probe`() {
        assertEquals("120", ProviderRejection.fromLog("HTTP error 429\r\nRetry-After: 120\r\n", "https://example.com/private")!!.retryAfter)
        assertEquals("Wed, 21 Oct 2026 07:28:00 GMT", ProviderRejection.fromLog("HTTP 503\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT", null)!!.retryAfter)
        assertNull(ProviderRejection.fromLog("HTTP error 503 Service Unavailable", null))
    }
    @Test
    fun `mpv HTTP log refusals are terminal and never export credentials`() {
        for (status in listOf(401, 403, 429)) {
            val rejection = ProviderRejection.fromLog("HTTP error $status", "https://host.test/live/secret")!!
            assertEquals(status, rejection.httpStatus)
            assertEquals("https://host.test/", rejection.responseOrigin)
        }
        assertNull(ProviderRejection.fromLog("codec 403 failed", null))
        assertNull(ProviderRejection.fromLog("HTTP error 503", null))
    }

    @Test
    fun `private response paths never enter channel fields or diagnostic text`() {
        val rejection = ProviderRejection.fromResponse(
            429,
            mapOf("rEtRy-AfTeR" to listOf(" 3600 ")),
            "https://login:password@edge.example:8443/live/account/secret.ts?token=private#fragment",
        )!!

        assertEquals(429, rejection.httpStatus)
        assertEquals("3600", rejection.retryAfter)
        assertEquals("https://edge.example:8443/", rejection.responseOrigin)
        assertEquals("HTTP 429", rejection.toString())
        assertEquals(
            mapOf("httpStatus" to 429, "retryAfter" to "3600", "responseOrigin" to "https://edge.example:8443/"),
            rejection.eventFields(),
        )
        for (secret in listOf("login", "password", "account", "secret.ts", "private", "fragment")) {
            assertFalse(rejection.eventFields().toString().contains(secret))
        }
    }

    @Test
    fun `HTTP date is preserved and unrelated statuses are not classified as refusals`() {
        val date = "Wed, 21 Oct 2026 07:28:00 GMT"
        assertEquals(
            date,
            ProviderRejection.fromResponse(403, mapOf("Retry-After" to listOf(date)), null)!!.retryAfter,
        )
        assertNull(ProviderRejection.fromResponse(500, emptyMap(), "https://example.com/"))
        assertEquals(mapOf("httpStatus" to 401), ProviderRejection.fromResponse(401, emptyMap(), null)!!.eventFields())
    }

    @Test
    fun `503 stops only when the server supplies valid retry timing`() {
        assertNull(ProviderRejection.fromResponse(503, emptyMap(), null))
        for (invalid in listOf("", "-1", "tomorrow", "secret-provider-token", "999999999999999999999999999")) {
            assertNull(ProviderRejection.fromResponse(503, mapOf("Retry-After" to listOf(invalid)), null))
        }
        for (valid in listOf("0", "3600", "Wed, 21 Oct 2026 07:28:00 GMT")) {
            assertEquals(valid, ProviderRejection.fromResponse(503, mapOf("Retry-After" to listOf(valid)), null)!!.retryAfter)
        }
        assertNull(ProviderRejection.fromResponse(429, mapOf("Retry-After" to listOf("secret-provider-token")), null)!!.retryAfter)
    }

    @Test
    fun `invalid response origins are omitted and IPv6 origins retain only host and port`() {
        for (url in listOf("not a URL", "file:///private/secret", "https:///private")) {
            assertNull(ProviderRejection.fromResponse(429, emptyMap(), url)!!.responseOrigin)
        }
        assertEquals(
            "http://[::1]:8080/",
            ProviderRejection.fromResponse(429, emptyMap(), "http://[::1]:8080/private?token=secret")!!.responseOrigin,
        )
    }

    @Test
    fun `redirected refusal retains final host and retry header without another request`() {
        val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        server.soTimeout = 2_000
        val requests = AtomicInteger()
        val serving = CompletableFuture.runAsync {
            repeat(2) { index ->
                server.accept().use { socket ->
                    socket.soTimeout = 2_000
                    val reader = socket.getInputStream().bufferedReader()
                    reader.readLine()
                    while (reader.readLine()?.isNotEmpty() == true) { /* Request headers. */ }
                    requests.incrementAndGet()
                    socket.getOutputStream().bufferedWriter().use { writer ->
                        val status = if (index == 0) "302 Found" else "429 Too Many Requests"
                        val header = if (index == 0) {
                            "Location: http://localhost:${server.localPort}/private/account/secret?token=hidden"
                        } else {
                            "Retry-After: 3600"
                        }
                        writer.write("HTTP/1.1 $status\r\n$header\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        writer.flush()
                    }
                }
            }
        }
        serving.whenComplete { _, _ -> server.close() }
        try {
            val port = server.localPort
            val connection = URL("http://127.0.0.1:$port/entry").openConnection() as HttpURLConnection
            connection.connectTimeout = 2_000
            connection.readTimeout = 2_000
            try {
                val status = connection.responseCode
                // Media3 disconnects before throwing, but retains the connection until close().
                val headers = connection.headerFields.filterKeys { it != null }
                connection.disconnect()
                val rejection = ProviderRejection.fromResponse(status, headers, connection.url.toString())!!
                assertEquals("http://localhost:$port/", rejection.responseOrigin)
                assertEquals("3600", rejection.retryAfter)
                assertEquals(2, requests.get())
                serving.get(5, TimeUnit.SECONDS)
            } finally {
                connection.disconnect()
            }
        } finally {
            server.close()
        }
    }
}
