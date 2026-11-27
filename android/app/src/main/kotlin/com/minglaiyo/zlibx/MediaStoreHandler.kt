package com.minglaiyo.zlibx

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/// The media_store channel must only touch this app's own
/// Downloads/zlibx entries: authority `media`, path under
/// `/external/downloads`. Anything else (file://, another provider,
/// another collection) is refused — the channel is only ever called
/// with URIs [MediaStoreHandler.publishToDownloads] /
/// [PendingDownloadHandler.createPendingDownload] returned, which
/// always live there. Shared with ShareHandler (same allowlist before
/// it copies a URI to the cache).
internal fun isAllowedDownloadUri(uri: Uri): Boolean {
    return uri.scheme == "content" &&
        uri.authority == "media" &&
        (uri.path?.startsWith("/external/downloads") == true)
}

/// Organize-mode subfolder under Download/zlibx, sanitized on
/// this side too (defense in depth — the Dart side already strips
/// these, but a bad value must never escape the download
/// directory). Null when organizing is off or the name is unusable.
/// Shared with PendingDownloadHandler (same relative path).
internal fun sanitizeSubfolder(raw: String?): String? {
    if (raw == null) return null
    val cleaned = raw
        .replace(Regex("[/\\\\:*?\"<>|\\x00-\\x1f]"), "")
        .trim()
    if (cleaned.isEmpty() || cleaned.all { it == '.' }) return null
    return cleaned
}

internal fun downloadRelativePath(subfolder: String?): String {
    val clean = sanitizeSubfolder(subfolder)
    return if (clean == null) "Download/zlibx" else "Download/zlibx/$clean"
}

/// MediaStore side of the `zlibx/media_store` channel: publishing a
/// finished file into the public Downloads/zlibx folder, and the
/// content:// operations on the URIs that come back from it (open /
/// exists / delete / real path).
///
/// P1-2 error discipline: a failure throws [ChannelFailure] so the
/// runner answers `result.error` with a stable code; Dart already
/// maps every one of these calls to the same null / false fallback
/// it used to get from a swallowed null. Two deliberate exceptions,
/// both load-bearing for Dart fallbacks:
/// - [contentExists] still returns false on any failure: false IS
///   the answer ("not there"), and Dart's exists() only runs its
///   real-path recovery when the call returns instead of throwing.
/// - [openContent] is synchronous (ACTION_VIEW) and keeps its
///   Boolean return; it never went through runAsync.
class MediaStoreHandler(
    private val context: Context,
    private val runner: ChannelRunner,
) {

    /// Dispatches the media_store methods this handler owns.
    /// Returns true when [call] was handled (including a direct
    /// missing-argument reply); false when it belongs to another
    /// handler or is unknown.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "publishToDownloads" -> {
                val sourcePath = call.argument<String>("sourcePath")
                val displayName = call.argument<String>("displayName")
                val mimeType = call.argument<String>("mimeType")
                val subfolder = call.argument<String>("subfolder")
                if (sourcePath == null || displayName == null || mimeType == null) {
                    result.success(null)
                } else {
                    runner.runAsync(result, runner.ioExecutor, "publish_failed") {
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
                    runner.runAsync(result, runner.lightExecutor, "content_exists_failed") {
                        contentExists(uri)
                    }
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
                    runner.runAsync(result, runner.lightExecutor, "delete_failed") {
                        deleteContent(uri)
                    }
                }
            }
            "realPathForContent" -> {
                // #123：content:// URI 不是文件管理器能搜的路径，
                // 查 MediaStore 的 RELATIVE_PATH + DISPLAY_NAME
                // 拼出真实路径（/storage/emulated/0/Download/...）。
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(null)
                } else {
                    runner.runAsync(result, runner.lightExecutor, "real_path_failed") {
                        realPathForContent(uri)
                    }
                }
            }
            else -> return false
        }
        return true
    }

    /// Insert [sourcePath] into the public Downloads/zlibx folder
    /// (MediaStore, Android 10+). Returns the content URI string.
    /// Throws [ChannelFailure] ("publish_failed") on any failure —
    /// the caller keeps the app-specific file in that case.
    /// (minSdk is 29, so the old "unsupported pre-Android 10" null
    /// can no longer occur; null used to mean failure here.)
    fun publishToDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String,
        subfolder: String? = null,
    ): String {
        val source = File(sourcePath)
        if (!source.exists()) {
            throw ChannelFailure("publish_failed", "source file missing")
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, downloadRelativePath(subfolder))
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: throw ChannelFailure("publish_failed", "insert returned null")
        try {
            val out = context.contentResolver.openOutputStream(uri)
            if (out == null) {
                context.contentResolver.delete(uri, null, null)
                throw ChannelFailure("publish_failed", "output stream unavailable")
            }
            out.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            context.contentResolver.update(uri, values, null, null)
            return uri.toString()
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore publish failed", e)
            try {
                context.contentResolver.delete(uri, null, null)
            } catch (cleanupError: Exception) {
                // Best-effort cleanup of the half-written entry.
                Log.w(NATIVE_TAG, "MediaStore cleanup failed", cleanupError)
            }
            throw ChannelFailure("publish_failed", e.javaClass.simpleName)
        }
    }

    fun contentExists(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) return false
        return try {
            val stream = context.contentResolver.openInputStream(uri) ?: return false
            stream.close()
            true
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore exists check failed", e)
            false
        }
    }

    fun openContent(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) return false
        val type = context.contentResolver.getType(uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore open failed", e)
            false
        }
    }

    /// Delete a Downloads/zlibx entry. Throws [ChannelFailure]
    /// ("delete_failed") when the row cannot be deleted — including
    /// zero rows deleted (the entry is already gone, which Dart
    /// still reads as false, as before). A failed delete must be
    /// retryable / reportable upstream, not a silent false.
    fun deleteContent(uri: Uri): Boolean {
        if (!isAllowedDownloadUri(uri)) {
            throw ChannelFailure("not_allowed", "uri not allowed")
        }
        return try {
            if (context.contentResolver.delete(uri, null, null) > 0) {
                true
            } else {
                throw ChannelFailure("delete_failed", "no rows deleted")
            }
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore delete failed", e)
            throw ChannelFailure("delete_failed", e.javaClass.simpleName)
        }
    }

    /// #123: resolve a Downloads/zlibx content URI to its real
    /// filesystem path. RELATIVE_PATH (e.g. "Download/zlibx/") +
    /// DISPLAY_NAME under the external storage dir. Returns null when
    /// the row is gone or cannot be resolved; throws [ChannelFailure]
    /// ("not_allowed" for a URI outside this app's entries,
    /// "real_path_failed" for a resolver failure).
    fun realPathForContent(uri: Uri): String? {
        if (!isAllowedDownloadUri(uri)) {
            throw ChannelFailure("not_allowed", "uri not allowed")
        }
        return try {
            val projection = arrayOf(
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.DISPLAY_NAME,
            )
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
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
            Log.w(NATIVE_TAG, "MediaStore real path failed", e)
            throw ChannelFailure("real_path_failed", e.javaClass.simpleName)
        }
    }
}
