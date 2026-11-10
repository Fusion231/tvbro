package com.gchofficial.iptvs.player

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource

/** Capture the final response origin before Media3 closes the failed source and forgets its URI. */
@UnstableApi
class ProviderHttpDataSource(
    private val upstream: HttpDataSource,
    private val connections: ProviderConnectionTracker? = null,
) : HttpDataSource by upstream {
    private var opened = false
    override fun open(dataSpec: DataSpec): Long = try {
        if (!opened) { opened = true; connections?.opened() }
        upstream.open(dataSpec)
    } catch (error: HttpDataSource.InvalidResponseCodeException) {
        val rejection = ProviderRejection.fromResponse(
            error.responseCode,
            error.headerFields,
            upstream.uri?.toString() ?: error.dataSpec.uri.toString(),
        )
        if (rejection == null) throw error
        throw ProviderHttpRejection(error, rejection)
    }

    override fun close() {
        try { upstream.close() } finally {
            if (opened) { opened = false; connections?.closed() }
        }
    }
}

@UnstableApi
private class ProviderHttpRejection(
    error: HttpDataSource.InvalidResponseCodeException,
    val rejection: ProviderRejection,
) : HttpDataSource.HttpDataSourceException(
    rejection.toString(),
    error,
    error.dataSpec,
    PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
    HttpDataSource.HttpDataSourceException.TYPE_OPEN,
)

@UnstableApi
fun playbackProviderRejection(error: Throwable): ProviderRejection? {
    for (cause in generateSequence(error) { it.cause }.take(12)) {
        if (cause is ProviderHttpRejection) return cause.rejection
        if (cause is HttpDataSource.InvalidResponseCodeException) {
            return ProviderRejection.fromResponse(
                cause.responseCode,
                cause.headerFields,
                cause.dataSpec.uri.toString(),
            )
        }
    }
    return null
}
