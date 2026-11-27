package com.minglaiyo.zlibx

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Truncate [name] to at most [maxBytes] UTF-8 bytes, cutting only
/// on a character boundary: a multi-byte character is never split
/// and a surrogate pair stays together. Returns the input
/// unchanged when it already fits. Shared with SafHandler (same
/// cache-file shape).
internal fun truncateUtf8Bytes(name: String, maxBytes: Int): String {
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

/// Cache file name for a file being shared / materialized:
/// `share_<millis>_<stem>` with the stem cut to 120 UTF-8 bytes and
/// the extension to 16 (same caps as the Dart shareCacheName —
/// Android caps a file name at 255 bytes and a CJK title costs 3
/// bytes per character, so a long title plus the "share_<millis>_"
/// prefix (20 bytes) would otherwise overflow the cap and the share
/// would silently fail). Only path separators are stripped, so CJK
/// and other name characters stay intact.
internal fun shareTempFileName(rawName: String): String {
    val clean = rawName.replace('/', '_').replace('\\', '_')
    val dot = clean.lastIndexOf('.')
    val (stem, ext) = if (dot > 0 && dot < clean.length - 1) {
        clean.substring(0, dot) to clean.substring(dot)
    } else {
        clean to ""
    }
    return "share_${System.currentTimeMillis()}_" +
        truncateUtf8Bytes(stem, 120) + truncateUtf8Bytes(ext, 16)
}

/// Share side of the `zlibx/media_store` channel: copy the file
/// behind a content:// URI into the app cache dir so it can be
/// handed to share_plus as a plain file path (share_plus cannot
/// share a content:// URI directly).
///
/// P1-2: a failed copy throws [ChannelFailure] ("copy_failed" /
/// "not_allowed") instead of a silent null, so Dart can tell a
/// refused URI from a failed copy. Dart still reads either as null
/// (share fails), as before.
class ShareHandler(
    private val context: Context,
    private val runner: ChannelRunner,
) {

    /// Dispatches the media_store methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "copyContentToCache") return false
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.success(null)
        } else {
            runner.runAsync(result, runner.ioExecutor, "copy_failed") {
                copyContentToCache(uri)
            }
        }
        return true
    }

    /// Delete stale `share_*` temp files from previous shares. Called
    /// before each new copy and at startup (see MainActivity.onCreate);
    /// only regular files older than [maxAgeMillis] are removed, and only
    /// the `share_` prefix this class creates — nothing else in the
    /// cache dir is touched. Best-effort: failures are logged and
    /// never fail the copy. Runs on the IO worker, never on the
    /// platform thread.
    fun cleanupStaleShareFiles(
        maxAgeMillis: Long = 24L * 60L * 60L * 1000L,
    ) {
        val cutoff = System.currentTimeMillis() - maxAgeMillis
        val files = try {
            context.cacheDir.listFiles()
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "Share cleanup: cannot list cache dir", e)
            return
        } ?: return
        for (file in files) {
            if (!file.isFile) continue
            if (!file.name.startsWith("share_")) continue
            if (file.lastModified() >= cutoff) continue
            try {
                if (!file.delete()) {
                    Log.w(NATIVE_TAG, "Share cleanup: could not delete ${file.name}")
                }
            } catch (e: Exception) {
                Log.w(NATIVE_TAG, "Share cleanup: delete failed", e)
            }
        }
    }

    /// Copy the file behind [uri] into the app cache dir so it can be
    /// handed to share_plus as a plain file path (share_plus cannot
    /// share a content:// URI directly). Returns the temp file's
    /// absolute path. The temp file keeps the MediaStore display name
    /// when available, with a timestamp suffix to avoid collisions;
    /// it is left in the cache dir for the OS to reclaim (deleting it
    /// right after sharing could break the receiving app's read).
    /// Throws [ChannelFailure] on any failure.
    fun copyContentToCache(uri: Uri): String {
        // O9: refuse anything outside this app's Downloads/zlibx
        // entries before touching the ContentResolver.
        if (!isAllowedDownloadUri(uri)) {
            throw ChannelFailure("not_allowed", "uri not allowed")
        }
        cleanupStaleShareFiles()
        return try {
            val displayName = context.contentResolver.query(
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
            val rawName = displayName?.takeIf { it.isNotBlank() }
                ?: uri.lastPathSegment?.takeIf { it.isNotBlank() }
                ?: "shared_file"
            val file = File(context.cacheDir, shareTempFileName(rawName))
            // The stream is opened last, wrapped in `use` for its whole
            // lifetime: a failing name lookup above can no longer leak
            // it (the old order opened the stream first), and an
            // exception inside the copy closes it too.
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                file.outputStream().use { output ->
                    inputStream.copyTo(output)
                }
            } ?: throw ChannelFailure("copy_failed", "input stream unavailable")
            file.absolutePath
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "MediaStore copy to cache failed", e)
            throw ChannelFailure("copy_failed", e.javaClass.simpleName)
        }
    }
}
