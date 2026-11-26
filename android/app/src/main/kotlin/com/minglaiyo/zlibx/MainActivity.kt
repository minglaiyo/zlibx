package com.minglaiyo.zlibx

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Process
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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

        /// Request code for the Android 17 local-network permission
        /// (ACCESS_LOCAL_NETWORK), asked from the local-network channel.
        private const val REQUEST_LOCAL_NETWORK = 1001
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

    /// Pending reply for an in-flight local-network permission
    /// request. Only one may be outstanding; a second call while one
    /// is in flight is answered false at once (the caller retries).
    private var pendingLocalNetworkResult: MethodChannel.Result? = null

    /// Pending reply for an in-flight SAF folder pick. Only one may
    /// be outstanding; a second call while one is in flight is
    /// answered null at once (the caller retries).
    private var pendingTreePickResult: MethodChannel.Result? = null

    /// SAF folder picker (ACTION_OPEN_DOCUMENT_TREE). Registered as a
    /// property so it exists before onStart; StartActivityForResult
    /// (not OpenDocumentTree) so the intent can carry EXTRA_INITIAL_URI
    /// pointing at Download/zlibx. The picked tree URI is persisted
    /// (takePersistableUriPermission) and returned to Dart, which
    /// stores it; a cancel answers null.
    private val treePicker = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { outcome ->
        val pending = pendingTreePickResult
        pendingTreePickResult = null
        if (pending == null) return@registerForActivityResult
        val uri = if (outcome.resultCode == Activity.RESULT_OK) {
            outcome.data?.data
        } else {
            null
        }
        if (uri == null) {
            replyTreePick(pending, null)
            return@registerForActivityResult
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            replyTreePick(pending, uri.toString())
        } catch (e: Exception) {
            // The picker did not grant a persistable permission: the
            // tree could not be re-adopted after a restart, so treat
            // the pick as failed.
            Log.w(TAG, "takePersistableUriPermission failed", e)
            replyTreePick(pending, null)
        }
    }

    /// Answer the pending tree-pick reply, tolerating an engine that
    /// detached while the picker was up (same pattern as the
    /// local-network reply).
    private fun replyTreePick(result: MethodChannel.Result, uri: String?) {
        try {
            result.success(uri)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "tree pick reply after detach ignored", e)
        }
    }

    /// The ACTION_OPEN_DOCUMENT_TREE intent for the download folder,
    /// pre-positioned at Download/zlibx. EXTRA_INITIAL_URI is only a
    /// hint (ignored below API 26); the user can still navigate.
    private fun treePickIntent(): Intent {
        val initial = try {
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                "primary:Download/zlibx",
            )
        } catch (e: Exception) {
            Log.w(TAG, "tree initial URI failed", e)
            null
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            if (initial != null) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
            }
        }
    }

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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_LOCAL_NETWORK) return
        // Answer the Dart call that asked for the local-network
        // permission (see "ensureLocalNetworkPermission" above).
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        try {
            pendingLocalNetworkResult?.success(granted)
        } catch (e: IllegalStateException) {
            // Engine detached while the dialog was up.
            Log.w(TAG, "local network reply after detach ignored", e)
        }
        pendingLocalNetworkResult = null
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
                        val subfolder = call.argument<String>("subfolder")
                        if (sourcePath == null || displayName == null || mimeType == null) {
                            result.success(null)
                        } else {
                            runAsync(result) {
                                publishToDownloads(
                                    sourcePath,
                                    displayName,
                                    mimeType,
                                    subfolder,
                                )
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
                    "pickDownloadTree" -> {
                        // SAF folder pick: the folder picker is a
                        // system UI, so this runs on the platform
                        // thread (never runAsync). The answer arrives
                        // later, through the launcher callback.
                        if (pendingTreePickResult != null) {
                            result.success(null)
                        } else {
                            pendingTreePickResult = result
                            treePicker.launch(treePickIntent())
                        }
                    }
                    "copyTreeFileToCache" -> {
                        val treeUri = call.argument<String>("treeUri")?.let(Uri::parse)
                        val relativePath = call.argument<String>("relativePath")
                        if (treeUri == null || relativePath.isNullOrEmpty()) {
                            result.success(null)
                        } else {
                            runAsync(result) {
                                copyTreeFileToCache(treeUri, relativePath)
                            }
                        }
                    }
                    "deleteTreeFile" -> {
                        val treeUri = call.argument<String>("treeUri")?.let(Uri::parse)
                        val relativePath = call.argument<String>("relativePath")
                        if (treeUri == null || relativePath.isNullOrEmpty()) {
                            result.success(false)
                        } else {
                            runAsync(result, lightExecutor) {
                                deleteTreeFile(treeUri, relativePath)
                            }
                        }
                    }
                    "persistedTreeUris" -> {
                        runAsync(result, lightExecutor) { persistedTreeUris() }
                    }
                    "realPathForContent" -> {
                        // #123：content:// URI 不是文件管理器能搜的路径，
                        // 查 MediaStore 的 RELATIVE_PATH + DISPLAY_NAME
                        // 拼出真实路径（/storage/emulated/0/Download/...）。
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null) {
                            result.success(null)
                        } else {
                            runAsync(result, lightExecutor) {
                                realPathForContent(uri)
                            }
                        }
                    }
                    "createPendingDownload" -> {
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType")
                        val subfolder = call.argument<String>("subfolder")
                        if (displayName == null || mimeType == null) {
                            result.success(null)
                        } else {
                            runAsync(result, lightExecutor) {
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

        // Web service: structured network state for the address picker.
        // Dart does the selection; this only reports facts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zlibx/network_state")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "lanAddressInfo" -> runAsync(result, lightExecutor) {
                        lanAddressInfo()
                    }
                    else -> result.notImplemented()
                }
            }

        // Web service: the Android 17 local-network permission only.
        // The HTTP server itself is a Dart HttpServer now (the native
        // LanWebServer rewrite was reverted — the socket was never the
        // problem, the missing permission was). Dart asks here before
        // binding, so other devices can actually reach the server.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zlibx/local_network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureLocalNetworkPermission" -> {
                        // Android 17+ (targetSdk 37) blocks local-network
                        // sockets without ACCESS_LOCAL_NETWORK: without it,
                        // inbound TCP from other devices times out in the
                        // network stack, before the SYN reaches our socket.
                        // Below API 37 the gate does not exist.
                        if (Build.VERSION.SDK_INT < 37) {
                            result.success(true)
                        } else if (ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.ACCESS_LOCAL_NETWORK,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else if (pendingLocalNetworkResult != null) {
                            result.success(false)
                        } else {
                            pendingLocalNetworkResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK),
                                REQUEST_LOCAL_NETWORK,
                            )
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
                    "cancelStale" -> {
                        // 新引擎启动：清掉上一个引擎留下的孤儿服务/通知。
                        DownloadForegroundService.cancelStale(this)
                        result.success(null)
                    }
                    "md5OfContent" -> {
                        // 外部源下载完成后的内容校验（审查 5.1）：流式
                        // MD5 在 ioExecutor 上跑——几百 MB 的文件不能占
                        // 主线程；算完回主线程答 result。
                        val target = call.argument<String>("uri") ?: ""
                        ioExecutor.execute {
                            val hash = md5OfContent(target)
                            runOnUiThread { result.success(hash) }
                        }
                    }
                    "updateProgress" -> {
                        DownloadForegroundService.updateProgress(
                            call.argument<String>("text"),
                        )
                        result.success(null)
                    }
                    "notifyCompleted" -> {
                        // E3+F4: 完成通知（副文本带当日剩余额度），点击直达文件。
                        DownloadForegroundService.notifyCompleted(
                            this,
                            call.argument<String>("title") ?: "zlibx",
                            call.argument<String>("uri") ?: "",
                            call.argument<String>("mimeType") ?: "*/*",
                            call.argument<String>("detail") ?: "下载完成",
                        )
                        result.success(null)
                    }
                    "setActionChannel" -> {
                        _downloadActionChannel = MethodChannel(
                            flutterEngine.dartExecutor.binaryMessenger,
                            call.argument<String>("name")
                                ?: "zlibx/download_service_action",
                        )
                        DownloadForegroundService.onAction = { action ->
                            _downloadActionChannel?.invokeMethod(action, null)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Backup import: restart the whole process so the freshly
        // imported Hive boxes and providers are re-read from scratch.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zlibx/app_restart")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "restart" -> {
                        result.success(null)
                        restartApp()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Restart the whole process: schedule the launcher activity via
    /// AlarmManager, then kill this process. Used after a backup import
    /// so the freshly imported Hive boxes and providers are re-read from
    /// scratch. (A widget-tree-only restart would leave Hive boxes and
    /// Riverpod state holding pre-import data.)
    private fun restartApp() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        } ?: return
        val pending = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
        )
        val alarm = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.set(AlarmManager.RTC, System.currentTimeMillis() + 100, pending)
        Process.killProcess(Process.myPid())
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

    /// Streaming MD5 of a download product (review 2026-11-21 5.1):
    /// content URIs read through the ContentResolver, plain paths through
    /// a FileInputStream — 64 KB chunks, nothing buffered in memory (a
    /// few hundred MB PDF must not be materialized to hash it). Returns
    /// lowercase hex, or null on any failure: the Dart side fails open
    /// (a broken checksum channel must not throw away a downloaded book).
    private fun md5OfContent(uriOrPath: String): String? {
        return try {
            val input = if (uriOrPath.startsWith("content://")) {
                contentResolver.openInputStream(android.net.Uri.parse(uriOrPath))
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
            Log.w(TAG, "md5 of content failed", e)
            null
        }
    }

    /// Organize-mode subfolder under Download/zlibx, sanitized on
    /// this side too (defense in depth — the Dart side already strips
    /// these, but a bad value must never escape the download
    /// directory). Null when organizing is off or the name is unusable.
    private fun sanitizeSubfolder(raw: String?): String? {
        if (raw == null) return null
        val cleaned = raw
            .replace(Regex("[/\\\\:*?\"<>|\\x00-\\x1f]"), "")
            .trim()
        if (cleaned.isEmpty() || cleaned.all { it == '.' }) return null
        return cleaned
    }

    private fun downloadRelativePath(subfolder: String?): String {
        val clean = sanitizeSubfolder(subfolder)
        return if (clean == null) "Download/zlibx" else "Download/zlibx/$clean"
    }

    /// Insert [sourcePath] into the public Downloads/zlibx folder
    /// (MediaStore, Android 10+). Returns the content URI string, or
    /// null when unsupported (pre-Android 10) or on any failure; the
    /// caller keeps the app-specific file in that case.
    private fun publishToDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String,
        subfolder: String? = null,
    ): String? {
        val source = File(sourcePath)
        if (!source.exists()) return null
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, downloadRelativePath(subfolder))
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
        subfolder: String? = null,
    ): String? {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, downloadRelativePath(subfolder))
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

    /// #123: resolve a Downloads/zlibx content URI to its real
    /// filesystem path. RELATIVE_PATH (e.g. "Download/zlibx/") +
    /// DISPLAY_NAME under the external storage dir. Returns null when
    /// the row is gone or the URI is not ours (O9 allowlist).
    private fun realPathForContent(uri: Uri): String? {
        if (!isAllowedDownloadUri(uri)) return null
        return try {
            val projection = arrayOf(
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.DISPLAY_NAME,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val relIndex = cursor.getColumnIndex(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                )
                val nameIndex = cursor.getColumnIndex(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                )
                if (relIndex < 0 || nameIndex < 0) return null
                val relPath = cursor.getString(relIndex) ?: return null
                val displayName = cursor.getString(nameIndex) ?: return null
                val external = Environment.getExternalStorageDirectory()
                    .absolutePath
                // RELATIVE_PATH ends with '/', e.g. "Download/zlibx/".
                "$external/$relPath$displayName"
            }
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore real path failed", e)
            null
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

    /// Truncate [name] to at most [maxBytes] UTF-8 bytes, cutting only
    /// on a character boundary: a multi-byte character is never split
    /// and a surrogate pair stays together. Returns the input
    /// unchanged when it already fits.
    private fun truncateUtf8Bytes(name: String, maxBytes: Int): String {
        if (name.toByteArray(Charsets.UTF_8).size <= maxBytes) return name
        val out = StringBuilder()
        var used = 0
        var i = 0
        while (i < name.length) {
            val cp = name.codePointAt(i)
            val charCount = Character.charCount(cp)
            val cpBytes = String(Character.toChars(cp))
                .toByteArray(Charsets.UTF_8).size
            if (used + cpBytes > maxBytes) break
            out.append(name, i, i + charCount)
            used += cpBytes
            i += charCount
        }
        return out.toString()
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
            // Android caps a file name at 255 bytes and a CJK title
            // costs 3 bytes per character, so a long title plus the
            // "share_<millis>_" prefix (20 bytes) overflows the cap:
            // outputStream() then throws and the share silently fails
            // (review P1-4). Truncate the stem to 120 UTF-8 bytes and
            // keep the extension, both cut on character boundaries.
            val rawName = (displayName?.takeIf { it.isNotBlank() }
                ?: uri.lastPathSegment?.takeIf { it.isNotBlank() }
                ?: "shared_file")
                .replace('/', '_')
                .replace('\\', '_')
            val dot = rawName.lastIndexOf('.')
            val (stem, ext) = if (dot > 0 && dot < rawName.length - 1) {
                rawName.substring(0, dot) to rawName.substring(dot)
            } else {
                rawName to ""
            }
            val safeName = truncateUtf8Bytes(stem, 120) +
                truncateUtf8Bytes(ext, 16)
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

    // ── SAF folder access (Download/zlibx) ──────────────────────────
    //
    // A clear-data orphans the MediaStore rows of already-downloaded
    // books (owner_package_name NULL): the app can still stat the files
    // but open() throws EACCES, so open / share / web streaming all
    // fail for them while fresh downloads work. MANAGE_EXTERNAL_STORAGE
    // was rejected by the user in favour of folder-scoped SAF: the
    // user picks Download/zlibx once in the system picker and the
    // grant is persisted, so only that folder is ever accessed.
    // Files are read through the DocumentsContract APIs (no
    // androidx.documentfile dependency): a tree file is materialized
    // into the cache first (same share_<millis>_<name> shape as
    // copyContentToCache), then the existing File-based paths use it.

    /// Walk [relativePath] ('sub/Book.epub' segments) under the SAF
    /// tree [treeUri] and return the leaf document ID, or null when
    /// any segment is missing or is not a file. Only framework
    /// DocumentsContract queries — no extra dependency.
    private fun findTreeDocumentId(treeUri: Uri, relativePath: String): String? {
        var parentId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            Log.w(TAG, "SAF tree document ID failed", e)
            return null
        }
        for (segment in relativePath.split('/')) {
            if (segment.isEmpty() || segment == "." || segment == "..") {
                return null
            }
            parentId = findTreeChildId(treeUri, parentId, segment) ?: return null
        }
        // The leaf must be a file, not a directory.
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
            val mime = contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) null else parentId
        } catch (e: Exception) {
            Log.w(TAG, "SAF leaf mime check failed", e)
            null
        }
    }

    /// The child of [parentId] named [name], or null. The provider is
    /// not trusted to honour a selection, so all children are listed
    /// and matched in Kotlin (a download folder holds tens of files).
    private fun findTreeChildId(treeUri: Uri, parentId: String, name: String): String? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentId,
        )
        return try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
                if (idIndex < 0 || nameIndex < 0) return null
                while (cursor.moveToNext()) {
                    if (cursor.getString(nameIndex) == name) {
                        return cursor.getString(idIndex)
                    }
                }
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "SAF child lookup failed", e)
            null
        }
    }

    /// Copy the tree file at [relativePath] into the app cache dir
    /// (same share_<millis>_<name> shape as copyContentToCache) and
    /// return the temp file's absolute path, or null on any failure.
    private fun copyTreeFileToCache(treeUri: Uri, relativePath: String): String? {
        cleanupStaleShareFiles()
        return try {
            val docId = findTreeDocumentId(treeUri, relativePath) ?: return null
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            val displayName = contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            val rawName = (displayName?.takeIf { it.isNotBlank() }
                ?: relativePath.substringAfterLast('/').takeIf { it.isNotBlank() }
                ?: "shared_file")
                .replace('/', '_')
                .replace('\\', '_')
            val dot = rawName.lastIndexOf('.')
            val (stem, ext) = if (dot > 0 && dot < rawName.length - 1) {
                rawName.substring(0, dot) to rawName.substring(dot)
            } else {
                rawName to ""
            }
            val safeName = truncateUtf8Bytes(stem, 120) +
                truncateUtf8Bytes(ext, 16)
            val file = File(
                cacheDir,
                "share_${System.currentTimeMillis()}_$safeName",
            )
            contentResolver.openInputStream(docUri)?.use { inputStream ->
                file.outputStream().use { output ->
                    inputStream.copyTo(output)
                }
            } ?: return null
            file.absolutePath
        } catch (e: Exception) {
            Log.w(TAG, "SAF copy to cache failed", e)
            null
        }
    }

    /// Delete the tree file at [relativePath]. False when missing or
    /// when the delete fails.
    private fun deleteTreeFile(treeUri: Uri, relativePath: String): Boolean {
        return try {
            val docId = findTreeDocumentId(treeUri, relativePath) ?: return false
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            DocumentsContract.deleteDocument(contentResolver, docUri)
        } catch (e: Exception) {
            Log.w(TAG, "SAF delete failed", e)
            false
        }
    }

    /// Tree URIs this app still holds a persisted read grant for, from
    /// the external-storage documents provider (used to re-adopt a
    /// grant after a clear-data wiped the stored URI string).
    private fun persistedTreeUris(): List<String> {
        return try {
            contentResolver.persistedUriPermissions
                .filter {
                    it.isReadPermission &&
                        it.uri.authority == "com.android.externalstorage.documents"
                }
                .map { it.uri.toString() }
        } catch (e: Exception) {
            Log.w(TAG, "persisted tree URIs failed", e)
            emptyList()
        }
    }

    // ── Web service: network state (zlibx/network_state) ───────────────

    /// Facts for the Dart address picker (see lan_share.dart):
    /// `hotspotOn`, `wifiConnected` and one entry per IPv4 interface with
    /// a `kind` of hotspot / wifi / cellular / other. Hotspot interface
    /// names come from, in order: TetheringManager (API 30+) →
    /// ConnectivityManager.tetheredInterfaces (API 24+) → DhcpInfo's
    /// server address, which only counts when it is non-zero AND Wi-Fi
    /// is not enabled (otherwise it is the upstream router, not us).
    private fun lanAddressInfo(): Map<String, Any?> {
        val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
            as? android.net.ConnectivityManager

        val wifiNames = HashSet<String>()
        val cellularNames = HashSet<String>()
        try {
            @Suppress("DEPRECATION")
            val networks = cm?.allNetworks ?: emptyArray()
            for (network in networks) {
                val caps = cm?.getNetworkCapabilities(network) ?: continue
                val name = cm?.getLinkProperties(network)?.interfaceName ?: continue
                if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) {
                    wifiNames.add(name)
                } else if (caps.hasTransport(
                        android.net.NetworkCapabilities.TRANSPORT_CELLULAR,
                    )
                ) {
                    cellularNames.add(name)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "network classification failed", e)
        }

        val hotspotNames = tetheredInterfaceNames(cm)

        // DhcpInfo fallback: usable as the hotspot address only when
        // Wi-Fi is NOT enabled and the server address is non-zero.
        var dhcpHotspotAddress: String? = null
        try {
            @Suppress("DEPRECATION")
            val wifi = applicationContext.getSystemService(
                android.content.Context.WIFI_SERVICE,
            ) as? android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            val server = wifi?.dhcpInfo?.serverAddress ?: 0
            if (wifi != null && !wifi.isWifiEnabled && server != 0) {
                dhcpHotspotAddress = String.format(
                    java.util.Locale.US,
                    "%d.%d.%d.%d",
                    server and 0xff,
                    (server shr 8) and 0xff,
                    (server shr 16) and 0xff,
                    (server shr 24) and 0xff,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "dhcp info failed", e)
        }

        val interfaces = ArrayList<Map<String, Any?>>()
        var hotspotSeen = false
        try {
            val all = java.net.NetworkInterface.getNetworkInterfaces()
            while (all != null && all.hasMoreElements()) {
                val iface = all.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val kind = when {
                    hotspotNames.contains(iface.name) -> "hotspot"
                    wifiNames.contains(iface.name) -> "wifi"
                    cellularNames.contains(iface.name) -> "cellular"
                    else -> "other"
                }
                for (addr in iface.inetAddresses.toList()) {
                    if (addr !is java.net.Inet4Address || addr.isLoopbackAddress) continue
                    val text = addr.hostAddress ?: continue
                    if (kind == "hotspot") hotspotSeen = true
                    interfaces.add(
                        mapOf("name" to iface.name, "address" to text, "kind" to kind),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "interface listing failed", e)
        }

        // Neither tethering API named an interface: DhcpInfo's address
        // is the hotspot address. Re-label the interface that owns it
        // (or report it by itself if none does).
        if (!hotspotSeen && dhcpHotspotAddress != null) {
            val index = interfaces.indexOfFirst { it["address"] == dhcpHotspotAddress }
            if (index >= 0) {
                interfaces[index] = interfaces[index] + ("kind" to "hotspot")
            } else {
                interfaces.add(
                    mapOf(
                        "name" to "dhcp",
                        "address" to dhcpHotspotAddress,
                        "kind" to "hotspot",
                    ),
                )
            }
            hotspotSeen = true
        }

        return mapOf(
            "hotspotOn" to hotspotSeen,
            "wifiConnected" to wifiNames.isNotEmpty(),
            "interfaces" to interfaces,
        )
    }

    /// Tethered (hotspot / USB / BT) interface names. Both public-looking
    /// APIs are hidden / permission-gated on many releases, so each is
    /// called reflectively and any failure just falls through to the
    /// next source — an empty set is a normal answer here.
    private fun tetheredInterfaceNames(
        cm: android.net.ConnectivityManager?,
    ): Set<String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val tm = getSystemService("tethering")
                if (tm != null) {
                    val method = tm.javaClass.getMethod("getTetheredInterfaces")
                    @Suppress("UNCHECKED_CAST")
                    val names = method.invoke(tm) as? Collection<String>
                    if (!names.isNullOrEmpty()) return names.toSet()
                }
            } catch (e: Exception) {
                Log.i(TAG, "TetheringManager unavailable: ${e.javaClass.simpleName}")
            }
        }
        try {
            val method = android.net.ConnectivityManager::class.java
                .getMethod("getTetheredIfaces")
            @Suppress("UNCHECKED_CAST")
            val names = method.invoke(cm) as? Array<String>
            if (!names.isNullOrEmpty()) return names.toSet()
        } catch (e: Exception) {
            Log.i(TAG, "tetheredInterfaces unavailable: ${e.javaClass.simpleName}")
        }
        return emptySet()
    }
}
