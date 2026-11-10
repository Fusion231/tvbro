package com.gchofficial.iptvs.player

import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** Fixed messages only: exception text can contain private media locators. */
fun playbackErrorMessage(
    error: Throwable? = null,
    httpStatus: Int? = null,
    connectionLost: Boolean = false,
): String {
    val causes = generateSequence(error) { it.cause }.take(12).toList()
    val status = httpStatus ?: causes.firstNotNullOfOrNull { cause ->
        Regex("(?i)\\b(?:HTTP(?:/\\d(?:\\.\\d)?)?(?:\\s+error)?(?:\\s*[:=]\\s*|\\s+)|response code:\\s*)(\\d{3})\\b")
            .find(cause.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()
    }
    if (status != null) {
        val message = when (status) {
            401, 403 -> "The provider rejected access (HTTP {status}). Check your account or subscription with your provider."
            404, 410 -> "The provider could not find this stream (HTTP {status}). Try another channel or contact your provider."
            429 -> "The provider is limiting requests (HTTP {status}). Wait a few minutes before trying again."
            else -> "The provider returned an error (HTTP {status}). Try again later or contact your provider."
        }
        return playerText(message).replace("{status}", status.toString())
    }
    val cause = causes.firstOrNull { it is UnknownHostException || it is SocketTimeoutException ||
        it is SSLException || it is ConnectException || it is SocketException }
    val detail = when (cause) {
        is UnknownHostException -> "The provider address could not be found. Check your connection and the source address."
        is SocketTimeoutException -> "The provider did not respond in time. Check your connection and try again."
        is SSLException -> "A secure connection to the provider could not be established. Check the device date and the source HTTPS address."
        is ConnectException -> "The provider refused the connection. Check the source address and port, or try another network."
        is SocketException -> "The connection to the provider was interrupted. Check your connection and try again."
        else -> null
    }
    val lost = "The connection to the stream was lost. Automatic reconnection failed. Check your connection and try again."
    return when {
        connectionLost && detail != null -> "${playerText(lost)}\n${playerText(detail)}"
        connectionLost -> playerText(lost)
        detail != null -> playerText(detail)
        else -> playerText("The stream could not be started. Try again; if the problem persists, contact your provider.")
    }
}
