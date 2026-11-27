package com.minglaiyo.zlibx

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream

/// Pending-download side of the `zlibx/media_store` channel: the
/// IS_PENDING entry the download engine streams into, one batch at a
/// time, then publishes or aborts.
///
/// Every operation runs on the runner's [pendingExecutor] (single
/// thread, Dart-sent order). That ordering is what makes the
/// held-open streams below safe: a size query or an abort can never
/// overtake a write that was sent before it, and [pendingStreams]
/// needs no locking. Kept apart from the IO pool so a long share /
/// publish copy never stalls a download.
///
/// P1-2: failures throw [ChannelFailure] so Dart gets a
/// `result.error` with a stable code instead of a bare false.
/// - write: Dart rethrows the PlatformException and the writer
///   records it (code included) in _writeError, so the engine can
///   retry / report instead of failing with a generic "pending
///   write failed".
/// - finish / abort: Dart maps the error back to false, as before.
/// - size: -1 still means "unknown" (a legitimate answer, not a
///   failure), so it keeps its internal catch.
class PendingDownloadHandler(
    private val context: Context,
    private val runner: ChannelRunner,
) {

    /// One open append stream per pending entry (key = URI string),
    /// held for the whole download instead of open / write / close per
    /// batch. Only touched on [ChannelRunner.pendingExecutor].
    private class PendingStream(val out: OutputStream) {
        val openedAtNs: Long = System.nanoTime()
        var bytes: Long = 0L
        var writes: Int = 0
        var writeNs: Long = 0L
    }

    private val pendingStreams = HashMap<String, PendingStream>()

    /// Dispatches the media_store methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "createPendingDownload" -> {
                val displayName = call.argument<String>("displayName")
                val mimeType = call.argument<String>("mimeType")
                val subfolder = call.argument<String>("subfolder")
                if (displayName == null || mimeType == null) {
                    result.success(null)
                } else {
                    runner.runAsync(result, runner.lightExecutor, "pending_create_failed") {
                        createPendingDownload(displayName, mimeType, subfolder)
                    }
                }
            }
            "writePendingChunk" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val bytes = call.argument<ByteArray>("bytes")
                if (uri == null || bytes == null) {
                    result.success(false)
                } else {
                    // Runs on the pending worker: a batch must
                    // never be written on the platform thread.
                    runner.runAsync(result, runner.pendingExecutor, "pending_write_failed") {
                        writePendingChunk(uri, bytes)
                    }
                }
            }
            "finishPendingDownload" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(false)
                } else {
                    runner.runAsync(result, runner.pendingExecutor, "pending_finish_failed") {
                        finishPendingDownload(uri)
                    }
                }
            }
            "abortPendingDownload" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(false)
                } else {
                    runner.runAsync(result, runner.pendingExecutor, "pending_abort_failed") {
                        abortPendingDownload(uri)
                    }
                }
            }
            "pendingEntrySize" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(-1L)
                } else {
                    runner.runAsync(result, runner.pendingExecutor, "pending_size_failed") {
                        pendingEntrySize(uri)
                    }
                }
            }
            else -> return false
        }
        return true
    }

    /// Insert a pending entry (IS_PENDING=1) into the public
    /// Downloads/zlibx folder (Android 10+). Returns the content URI
    /// string. Throws [ChannelFailure] ("pending_create_failed") on
    /// any failure — the caller then falls back to the staged .part
    /// flow. No bytes are written here — the caller streams them
    /// with [writePendingChunk] and publishes with
    /// [finishPendingDownload].
    fun createPendingDownload(
        displayName: String,
        mimeType: String,
        subfolder: String? = null,
    ): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, downloadRelativePath(subfolder))
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return try {
            context.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            )?.toString()
                ?: throw ChannelFailure("pending_create_failed", "insert returned null")
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending create failed", e)
            throw ChannelFailure("pending_create_failed", e.javaClass.simpleName)
        }
    }

    /// Append [bytes] to the pending entry [uri]. The first call for an
    /// entry opens a "wa" (append) stream and keeps it open in
    /// [pendingStreams]; later calls reuse it, so a download pays the
    /// ContentResolver open / close once instead of once per batch. The
    /// stream is closed by [finishPendingDownload] / [abortPendingDownload]
    /// (or here, on any write error, so a broken stream is never reused —
    /// the next call reopens in append mode at the true end of file).
    /// Throws [ChannelFailure] ("pending_write_failed") on any failure,
    /// including devices that refuse "wa".
    fun writePendingChunk(uri: Uri, bytes: ByteArray): Boolean {
        val key = uri.toString()
        return try {
            val stream = pendingStreams[key] ?: openPendingStream(uri, key)
                ?: throw ChannelFailure("pending_write_failed", "stream unavailable")
            val startNs = System.nanoTime()
            stream.out.write(bytes)
            stream.writeNs += System.nanoTime() - startNs
            stream.bytes += bytes.size.toLong()
            stream.writes += 1
            true
        } catch (e: ChannelFailure) {
            closePendingStream(key)
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending write failed", e)
            closePendingStream(key)
            throw ChannelFailure("pending_write_failed", e.javaClass.simpleName)
        }
    }

    private fun openPendingStream(uri: Uri, key: String): PendingStream? {
        val out = context.contentResolver.openOutputStream(uri, "wa")
        if (out == null) {
            Log.w(NATIVE_TAG, "MediaStore pending write: stream unavailable")
            return null
        }
        val stream = PendingStream(out)
        pendingStreams[key] = stream
        return stream
    }

    /// Close and forget the held stream for [key]. True when there was
    /// none or it closed cleanly. Logs one summary line (bytes, time
    /// spent inside write(), wall time since open) — `adb logcat -s
    /// ZlibxMediaStore` shows whether the MediaStore write path is a
    /// bottleneck: if write time is small next to wall time, the
    /// download is network-bound.
    private fun closePendingStream(key: String): Boolean {
        val stream = pendingStreams.remove(key) ?: return true
        val closed = try {
            stream.out.close()
            true
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending stream close failed", e)
            false
        }
        val writeMs = stream.writeNs / 1_000_000L
        val wallMs = (System.nanoTime() - stream.openedAtNs) / 1_000_000L
        val mibPerSec = if (stream.writeNs > 0L) {
            stream.bytes.toDouble() / 1048576.0 / (stream.writeNs / 1e9)
        } else {
            0.0
        }
        val rate = String.format(java.util.Locale.US, "%.1f", mibPerSec)
        Log.i(
            NATIVE_TAG,
            "pending stream closed: ${stream.bytes} B in ${stream.writes} " +
                "writes, write time $writeMs ms ($rate MiB/s), " +
                "wall $wallMs ms",
        )
        return closed
    }

    /// Close every held pending stream. Called from the Activity's
    /// onDestroy (entries stay IS_PENDING and resumable).
    fun closeAllPendingStreams() {
        for (key in pendingStreams.keys.toList()) {
            closePendingStream(key)
        }
    }

    /// Publish the pending entry by clearing IS_PENDING. The held write
    /// stream is closed first, so every byte is handed to the provider
    /// before the entry becomes visible. Throws [ChannelFailure]
    /// ("pending_finish_failed") on any failure (the caller then
    /// treats the download as failed and removes the entry with
    /// [abortPendingDownload]).
    fun finishPendingDownload(uri: Uri): Boolean {
        if (!closePendingStream(uri.toString())) {
            throw ChannelFailure("pending_finish_failed", "stream close failed")
        }
        return try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            if (context.contentResolver.update(uri, values, null, null) > 0) {
                true
            } else {
                throw ChannelFailure("pending_finish_failed", "no rows updated")
            }
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending finish failed", e)
            throw ChannelFailure("pending_finish_failed", e.javaClass.simpleName)
        }
    }

    /// Delete a pending entry (cleanup of a cancelled / failed /
    /// superseded download), closing its held write stream first.
    /// Throws [ChannelFailure] ("pending_abort_failed") on any
    /// failure (Dart reads it as false, as before).
    fun abortPendingDownload(uri: Uri): Boolean {
        closePendingStream(uri.toString())
        return try {
            if (context.contentResolver.delete(uri, null, null) > 0) {
                true
            } else {
                throw ChannelFailure("pending_abort_failed", "no rows deleted")
            }
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending abort failed", e)
            throw ChannelFailure("pending_abort_failed", e.javaClass.simpleName)
        }
    }

    /// Byte size of the pending entry [uri], read from its file
    /// descriptor (statSize). Used on resume to reconcile the persisted
    /// byte count: if the process died after a chunk was committed but
    /// before the sidecar was written, the sidecar lags the entry and
    /// resuming from it would duplicate bytes. Returns -1 when the size
    /// cannot be determined.
    fun pendingEntrySize(uri: Uri): Long {
        return try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                pfd.statSize
            } ?: -1L
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore pending size failed", e)
            -1L
        }
    }
}
