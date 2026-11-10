package com.gchofficial.iptvs.player

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.gchofficial.iptvs.MainActivity
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private val episodeArtworkSlots = Semaphore(3)
private val episodeArtworkCache = object : LruCache<String, Bitmap>(8 * 1024 * 1024) {
    override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
}

/** Lazy cards use Dart's shared guarded disk cache; native code never opens HTTP. */
@Composable
internal fun EpisodeArtwork(imageUrl: String?, modifier: Modifier = Modifier) {
    val request = remember(imageUrl) { imageUrl?.let(::EpisodeArtworkRequest) }
    var bitmap by remember(imageUrl) { mutableStateOf(imageUrl?.let(episodeArtworkCache::get)) }
    DisposableEffect(request) {
        onDispose { request?.cancel() }
    }
    LaunchedEffect(request) {
        if (bitmap == null && request != null) {
            bitmap = episodeArtworkSlots.withPermit { request.load() }
        }
    }
    Box(modifier.background(PlayerColors.PanelHi), contentAlignment = Alignment.Center) {
        val artwork = bitmap
        if (artwork == null) {
            Icon(Icons.Filled.Tv, contentDescription = null, tint = PlayerColors.TextLo, modifier = Modifier.size(28.dp))
        } else {
            Image(artwork.asImageBitmap(), contentDescription = null, modifier = Modifier.matchParentSize(), contentScale = ContentScale.Crop)
        }
    }
}

private class EpisodeArtworkRequest(private val imageUrl: String) {
    private val requestId = UUID.randomUUID().toString()
    @Volatile private var cancelled = false

    fun cancel() {
        cancelled = true
        MainActivity.instance?.get()?.cancelEpisodeArtwork(requestId)
    }

    suspend fun load(): Bitmap? {
        episodeArtworkCache.get(imageUrl)?.let { return it }
        if (cancelled) return null
        val path = withTimeoutOrNull(15_000) {
            suspendCancellableCoroutine<String?> { continuation ->
                continuation.invokeOnCancellation { cancel() }
                val host = MainActivity.instance?.get()
                if (host == null || cancelled) {
                    continuation.resume(null)
                } else {
                    host.requestEpisodeArtwork(requestId, imageUrl) { reply ->
                        if (continuation.isActive) continuation.resume(reply)
                    }
                }
            }
        } ?: return null
        if (cancelled) return null
        return withContext(Dispatchers.IO) { decode(path) }
    }

    private fun decode(path: String): Bitmap? {
        return try {
            val file = File(path)
            if (!file.isAbsolute || !file.isFile || file.length() > MAX_BYTES || cancelled) return null
            val bytes = file.inputStream().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                while (!cancelled) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > MAX_BYTES) return null
                    output.write(buffer, 0, count)
                }
                if (cancelled) return null
                output.toByteArray()
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || cancelled) return null
            var sample = 1
            while (bounds.outWidth / sample > 1120 || bounds.outHeight / sample > 630) sample *= 2
            val decoded = BitmapFactory.decodeByteArray(
                bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return null
            val scale = minOf(560f / decoded.width, 315f / decoded.height, 1f)
            val artwork = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    decoded, (decoded.width * scale).toInt().coerceAtLeast(1),
                    (decoded.height * scale).toInt().coerceAtLeast(1), true,
                ).also { if (it !== decoded) decoded.recycle() }
            } else decoded
            if (cancelled) {
                artwork.recycle()
                null
            } else {
                episodeArtworkCache.put(imageUrl, artwork)
                artwork
            }
        } catch (_: Exception) {
            null
        }
    }

    private companion object {
        const val MAX_BYTES = 6 * 1024 * 1024
    }
}
