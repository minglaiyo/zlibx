package com.minglaiyo.zlibx

import android.content.Context
import android.net.Uri
import android.util.Log

/// MD5 side of the `zlibx/download_service` channel (review v2 P1-3
/// HashHandler).
///
/// Runs on the runner's dedicated [ChannelRunner.hashExecutor], not
/// the IO pool: a few-hundred-MB hash must neither block a share
/// copy nor queue behind one.
///
/// Failure discipline (P1-2): null still means "could not hash"
/// and Dart fails open on null (a broken checksum channel must not
/// throw away a downloaded book), so the hash itself keeps its
/// internal catch. What P1-2 fixes here is the dispatch: the old
/// `md5OfContent` call did a bare `ioExecutor.execute` with no
/// try/catch, so after onDestroy shut the pool down it threw
/// RejectedExecutionException uncaught out of the MethodCallHandler.
/// It now goes through the runner, which answers `channel_shutdown`
/// instead.
class HashHandler(
    private val context: Context,
) {

    /// Streaming MD5 of a download product (review 2026-11-21 5.1):
    /// content URIs read through the ContentResolver, plain paths through
    /// a FileInputStream — 64 KB chunks, nothing buffered in memory (a
    /// few hundred MB PDF must not be materialized to hash it). Returns
    /// lowercase hex, or null on any failure: the Dart side fails open
    /// (a broken checksum channel must not throw away a downloaded book).
    fun md5OfContent(uriOrPath: String): String? {
        return try {
            val input = if (uriOrPath.startsWith("content://")) {
                context.contentResolver.openInputStream(Uri.parse(uriOrPath))
            } else {
                java.io.FileInputStream(java.io.File(uriOrPath))
            }
            input?.use { stream ->
                val md = java.security.MessageDigest.getInstance("MD5")
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    md.update(buffer, 0, read)
                }
                md.digest().joinToString("") { "%02x".format(it) }
            }
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "md5 of content failed", e)
            null
        }
    }
}
