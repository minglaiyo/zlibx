package com.open_library.app

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// FlutterFragmentActivity instead of FlutterActivity: the privacy
// lock's local_auth (BiometricPrompt) requires a FragmentActivity —
// FlutterActivity makes the biometric plugin throw on every call.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "zlibx/media_store"
        private const val TAG = "ZlibxMediaStore"
    }

    // File copies (publish to Downloads, copy to cache) can move hundreds
    // of MB; they must not run on the platform (UI) thread or the app
    // freezes / ANRs. A single worker keeps them ordered.
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // Cheap ContentResolver probes (exists / delete) get their own small
    // pool so they never queue behind a multi-hundred-MB copy.
    private val lightExecutor: ExecutorService = Executors.newFixedThreadPool(2)

    // Every operation on a pending download entry (append / size /
    // finish / abort) runs on this one thread, in the order Dart sent
    // them. That ordering is what makes the held-open streams below safe:
    // a size query or an abort can never overtake a write that was sent
    // before it, and [pendingStreams] needs no locking. Kept apart from
    // [ioExecutor] so a long share / publish copy never stalls a download.
    private val pendingExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /// One open append stream per pending entry (key = URI string),
    /// held for the whole download instead of open / write / close per
    /// batch. Only touched on [pendingExecutor].
    private class PendingStream(val out: OutputStream) {
        val openedAtNs: Long = System.nanoTime()
        var bytes: Long = 0L
        var writes: Int = 0
        var writeNs: Long = 0L
    }

    private val pendingStreams = HashMap<String, PendingStream>()

    /// Channel Dart listens on for download pause/cancel actions fired by
    /// the foreground-service notification (O1). Set when Dart registers
    /// its action handler.
    private var _downloadActionChannel: MethodChannel? = null

    override fun onDestroy() {
        // Close any held pending streams (entries stay IS_PENDING and
        // resumable), then let queued work drain.
        try {
            pendingExecutor.execute { closeAllPendingStreams() }
        } catch (e: Exception) {
            Log.w(TAG, "pending stream cleanup not scheduled", e)
        }
        pendingExecutor.shutdown()
        // shutdown() lets a running copy finish; it only rejects new work.
        ioExecutor.shutdown()
        lightExecutor.shutdown()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // O9: a share's temp copy lingered until the NEXT share (the old
        // code only cleaned before a new copy). Drop stale share_ files
        // at startup too, when no share from this process can be in
        // flight. One hour, not 24: a share target reads the file
        // within seconds of the share.
        try {
            ioExecutor.execute { cleanupStaleShareFiles(60L * 60L * 1000L) }
        } catch (e: Exception) {
            Log.w(TAG, "Share cleanup at startup not scheduled", e)
        }
    }

    /// Runs [block] on the worker thread and replies on the UI thread.
    private fun <T> runAsync(
        result: MethodChannel.Result,
        executor: ExecutorService = ioExecutor,
        block: () -> T?,
    ) {
        executor.execute {
            val value = try {
                block()
            } catch (e: Exception) {
                Log.w(TAG, "MediaStore task failed", e)
                null
            }
            runOnUiThread {
                try {
                    result.success(value)
                } catch (e: IllegalStateException) {
                    // Engine detached while the copy was running.
                    Log.w(TAG, "reply after detach ignored", e)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publishToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType")
                        if (sourcePath == null || displayName == null || mimeType == null) {
                            result.success(null)
                        } else {
                            runAsync(result) {
                                publishToDownloads(sourcePath, displayName, mimeType)
                            }
                        }
                    }
                    "contentExists" -> {
                        // openInputStream hits the ContentResolver / disk:
                        // keep it off the platform thread (the history
                        // check calls this once per entry at startup).
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(false)
                        } else {
                            runAsync(result, lightExecutor) { contentExists(uri) }
                        }
                    }
                    "openContent" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        result.success(uri != null && openContent(uri))
                    }
                    "setSecureFlag" -> {
                        // Privacy lock companion: FLAG_SECURE blurs this
                        // app in the recents screen and blocks screenshots.
                        // Main thread — a window flag change must run there.
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        runOnUiThread {
                            try {
                                if (enabled) {
                                    window.setFlags(
                                        android.view.WindowManager.LayoutParams.FLAG_SECURE,
                                        android.view.WindowManager.LayoutParams.FLAG_SECURE,
                                    )
                                } else {
                                    window.clearFlags(
                                        android.view.WindowManager.LayoutParams.FLAG_SECURE,
                                    )
                                }
                                result.success(true)
                            } catch (e: Exception) {
                                Log.w(TAG, "setSecureFlag failed", e)
                                result.success(false)
                            }
                        }
                    }
                    "deleteContent" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(false)
                        } else {
                            runAsync(result, lightExecutor) { deleteContent(uri) }
                        }
                    }
                    "copyContentToCache" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(null)
                        } else {
                            runAsync(result) { copyContentToCache(uri) }
                        }
                    }
                    "createPendingDownload" -> {
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType")
                        if (displayName == null || mimeType == null) {
                            result.success(null)
                        } else {
                            runAsync(result, lightExecutor) {
                                createPendingDownload(displayName, mimeType)
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
                            runAsync(result, pendingExecutor) {
                                writePendingChunk(uri, bytes)
                            }
                        }
                    }
                    "finishPendingDownload" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(false)
                        } else {
                            runAsync(result, pendingExecutor) {
                                finishPendingDownload(uri)
                            }
                        }
                    }
                    "abortPendingDownload" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(false)
                        } else {
                            runAsync(result, pendingExecutor) {
                                abortPendingDownload(uri)
                            }
                        }
                    }
                    "pendingEntrySize" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(-1L)
                        } else {
                            runAsync(result, pendingExecutor) {
                                pendingEntrySize(uri)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // O1: background download keep-alive. Dart starts/stops the
        // foreground service, pushes progress, and registers the channel
        // it listens on for pause/cancel actions from the notification.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zlibx/download_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(null)
                    }
                    "start" -> {
                        DownloadForegroundService.startDownload(this)
                        result.success(null)
                    }
                    "stop" -> {
                        DownloadForegroundService.endDownload(this)
                        result.success(null)
                    }
                    "updateProgress" -> {
                        DownloadForegroundService.updateProgress(
                            call.argument<String>("text"),
                        )
                        result.success(null)
                    }
                    "setActionChannel" -> {
                        _downloadActionChannel = MethodChannel(
                            flutterEngine.dartExecutor.binaryMessenger,
                            call.argument<String>()
                                ?: "zlibx/download_service_action",
                        )
                        DownloadForegroundService.onAction = { action ->
                            _downloadActionChannel?.invokeMethod(action)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// O1: request POST_NOTIFICATIONS on Android 13+ so the download
    /// progress notification is visible. Best-effort — the foreground
    /// service runs regardless; the notification is only suppressed
    /// without the grant.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
            == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                0,
            )
        } catch (e: Exception) {
            Log.w(TAG, "notification permission request failed", e)
        }
    }

    /// Insert [sourcePath] into the public Downloads/zlibx folder
    /// (MediaStore, Android 10+). Returns the content URI string, or
    /// null when unsupported (pre-Android 10) or on any failure; the
    /// caller keeps the app-specific file in that case.
    private fun publishToDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String,
    ): String? {
        val source = File(sourcePath)
        if (!source.exists()) return null
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/zlibx")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: return null
        try {
            val out = contentResolver.openOutputStream(uri)
            if (out == null) {
                contentResolver.delete(uri, null, null)
                return null
            }
            out.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore publish failed", e)
            try {
                contentResolver.delete(uri, null, null)
            } catch (cleanupError: Exception) {
                // Best-effort cleanup of the half-written entry.
                Log.w(TAG, "MediaStore cleanup failed", cleanupError)
            }
            return null
        }
    }

    /// Insert a pending entry (IS_PENDING=1) into the public
    /// Downloads/zlibx folder (Android 10+). Returns the content URI
    /// string, or null when unsupported (pre-Android 10) or on any
    /// failure. No bytes are written here — the caller streams them
    /// with [writePendingChunk] and publishes with
    /// [finishPendingDownload].
    private fun createPendingDownload(
        displayName: String,
        mimeType: String,
    ): String? {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/zlibx")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return try {
            contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            )?.toString()
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore pending create failed", e)
            null
        }
    }

    /// Append [bytes] to the pending entry [uri]. The first call for an
    /// entry opens a "wa" (append) stream and keeps it open in
    /// [pendingStreams]; later calls reuse it, so a download pays the
    /// ContentResolver open / close once instead of once per batch. The
    /// stream is closed by [finishPendingDownload] / [abortPendingDownload]
    /// (or here, on any write error, so a broken stream is never reused —
    /// the next call reopens in append mode at the true end of file).
    /// False on any failure, including devices that refuse "wa".
    private fun writePendingChunk(uri: Uri, bytes: ByteArray): Boolean {
        val key = uri.toString()
        return try {
            val stream = pendingStreams[key] ?: openPendingStream(uri, key)
            if (stream == null) {
                false
            } else {
                val startNs = System.nanoTime()
                stream.out.write(bytes)
                stream.writeNs += System.nanoTime() - startNs
                stream.bytes += bytes.size.toLong()
                stream.writes += 1
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore pending write failed", e)
            closePendingStream(key)
            false
        }
    }

    private fun openPendingStream(uri: Uri, key: String): PendingStream? {
        val out = contentResolver.openOutputStream(uri, "wa")
        if (out == null) {
            Log.w(TAG, "MediaStore pending write: stream unavailable")
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
            Log.w(TAG, "MediaStore pending stream close failed", e)
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
            TAG,
            "pending stream closed: ${stream.bytes} B in ${stream.writes} " +
                "writes, write time $writeMs ms ($rate MiB/s), " +
                "wall $wallMs ms",
        )
        return closed
    }

    private fun closeAllPendingStreams() {
        for (key in pendingStreams.keys.toList()) {
            closePendingStream(key)
        }
    }

    /// Publish the pending entry by clearing IS_PENDING. The held write
    /// stream is closed first, so every byte is handed to the provider
    /// before the entry becomes visible. False on any failure (the
    /// caller then treats the download as failed and removes the entry
    /// with [abortPendingDownload]).
    private fun finishPendingDownload(uri: Uri): Boolean {
        if (!closePendingStream(uri.toString())) return false
        return try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            contentResolver.update(uri, values, null, null) > 0
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore pending finish failed", e)
            false
        }
    }

    /// Delete a pending entry (cleanup of a cancelled / failed /
    /// superseded download), closing its held write stream first. False
    /// on any failure.
    private fun abortPendingDownload(uri: Uri): Boolean {
        closePendingStream(uri.toString())
        return try {
            contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore pending abort failed", e)
            false
        }
    }

    /// Byte size of the pending entry [uri], read from its file
    /// descriptor (statSize). Used on resume to reconcile the persisted
    /// byte count: if the process died after a chunk was committed but
    /// before the sidecar was written, the sidecar lags the entry and
    /// resuming from it would duplicate bytes. Returns -1 when the size
    /// cannot be determined.
    private fun pendingEntrySize(uri: Uri): Long {
        return try {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                pfd.statSize
            } ?: -1L
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore pending size failed", e)
            -1L
        }
    }

    /// O9: the media_store channel must only touch this app's own
    /// Downloads/zlibx entries: authority `media`, path under
    /// `/external/downloads`. Anything else (file://, another provider,
    /// another collection) is refused — the channel is only ever called
    /// with URIs [publishToDownloads] / [createPendingDownload]
    /// returned, which always live there.
    private fun isAllowedDownloadUri(uri: Uri): Boolean {
        return uri.scheme == "content" &&
            uri.authority == "media" &&
            (uri.path?.startsWith("/external/downloads") == true)
    }

    private fun contentExists(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) return false
        return try {
            val stream = contentResolver.openInputStream(uri) ?: return false
            stream.close()
            true
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore exists check failed", e)
            false
        }
    }

    private fun openContent(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) return false
        val type = contentResolver.getType(uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore open failed", e)
            false
        }
    }

    private fun deleteContent(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) return false
        return try {
            contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore delete failed", e)
            false
        }
    }

    /// Delete stale `share_*` temp files from previous shares. Called
    /// before each new copy and at startup (see [onCreate]); only
    /// regular files older than [maxAgeMillis] are removed, and only
    /// the `share_` prefix this class creates — nothing else in the
    /// cache dir is touched. Best-effort: failures are logged and
    /// never fail the copy. Runs on the IO worker (see [runAsync]),
    /// never on the platform thread.
    private fun cleanupStaleShareFiles(
        maxAgeMillis: Long = 24L * 60L * 60L * 1000L,
    ) {
        val cutoff = System.currentTimeMillis() - maxAgeMillis
        val files = try {
            cacheDir.listFiles()
        } catch (e: Exception) {
            Log.w(TAG, "Share cleanup: cannot list cache dir", e)
            return
        } ?: return
        for (file in files) {
            if (!file.isFile) continue
            if (!file.name.startsWith("share_")) continue
            if (file.lastModified() >= cutoff) continue
            try {
                if (!file.delete()) {
                    Log.w(TAG, "Share cleanup: could not delete ${file.name}")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Share cleanup: delete failed", e)
            }
        }
    }

    /// Copy the file behind [uri] into the app cache dir so it can be
    /// handed to share_plus as a plain file path (share_plus cannot
    /// share a content:// URI directly). Returns the temp file's
    /// absolute path, or null on any failure. The temp file keeps
    /// the MediaStore display name when available, with a timestamp
    /// suffix to avoid collisions; it is left in the cache dir for
    /// the OS to reclaim (deleting it right after sharing could
    /// break the receiving app's read).
    private fun copyContentToCache(uri: Uri): String? {
        // O9: refuse anything outside this app's Downloads/zlibx
        // entries before touching the ContentResolver.
        if (!isAllowedDownloadUri(uri)) return null
        cleanupStaleShareFiles()
        return try {
            val displayName = contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            // Keep CJK and other name characters intact; only strip
            // path separators so the name stays a single segment.
            val safeName = (displayName?.takeIf { it.isNotBlank() }
                ?: uri.lastPathSegment?.takeIf { it.isNotBlank() }
                ?: "shared_file")
                .replace('/', '_')
                .replace('\\', '_')
            val file = File(
                cacheDir,
                "share_${System.currentTimeMillis()}_$safeName",
            )
            // The stream is opened last, wrapped in `use` for its whole
            // lifetime: a failing name lookup above can no longer leak
            // it (the old order opened the stream first), and an
            // exception inside the copy closes it too.
            contentResolver.openInputStream(uri)?.use { inputStream ->
                file.outputStream().use { output ->
                    inputStream.copyTo(output)
                }
            } ?: return null
            file.absolutePath
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore copy to cache failed", e)
            null
        }
    }
}
