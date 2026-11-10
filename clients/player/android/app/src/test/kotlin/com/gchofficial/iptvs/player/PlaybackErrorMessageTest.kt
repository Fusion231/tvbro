package com.gchofficial.iptvs.player

import java.net.UnknownHostException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test

class PlaybackErrorMessageTest {
    @After fun restoreLanguage() { PlayerStrings.language = "en" }

    @Test fun nestedNetworkCauseIsReadableAndHidesLocators() {
        val message = playbackErrorMessage(IllegalStateException(
            "https://user:password@private.test/stream",
            UnknownHostException("private.test"),
        ))
        assertTrue(message.contains("address could not be found"))
        assertFalse(message.contains("private.test"))
        assertFalse(message.contains("password"))
    }

    @Test fun networkCausesRemainDistinct() {
        assertTrue(playbackErrorMessage(SocketTimeoutException()).contains("respond in time"))
        assertTrue(playbackErrorMessage(SSLHandshakeException("private")).contains("secure connection"))
        assertTrue(playbackErrorMessage(connectionLost = true).contains("Automatic reconnection failed"))
    }

    @Test fun providerHostNameIsNotAnHttpStatus() {
        val message = playbackErrorMessage(UnknownHostException("http503.private.test"))
        assertTrue(message.contains("address could not be found"))
        assertFalse(message.contains("HTTP 503"))
    }

    @Test fun httpAndPolishGuidanceSurviveTerminalRecovery() {
        PlayerStrings.language = "pl"
        val refused = playbackErrorMessage(httpStatus = 403, connectionLost = true)
        assertTrue(refused.contains("odmówił dostępu"))
        assertTrue(refused.contains("403"))
        val throttled = playbackErrorMessage(httpStatus = 429)
        assertTrue(throttled.contains("Poczekaj kilka minut"))
        assertTrue(playbackErrorMessage(connectionLost = true).contains("Utracono połączenie"))
    }
}
