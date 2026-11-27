package com.minglaiyo.zlibx

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// SAF folder access side of the `zlibx/media_store` channel
/// (Download/zlibx).
///
/// A clear-data orphans the MediaStore rows of already-downloaded
/// books (owner_package_name NULL): the app can still stat the files
/// but open() throws EACCES, so open / share / web streaming all
/// fail for them while fresh downloads work. MANAGE_EXTERNAL_STORAGE
/// was rejected by the user in favour of folder-scoped SAF: the
/// user picks Download/zlibx once in the system picker and the
/// grant is persisted, so only that folder is ever accessed.
/// Files are read through the DocumentsContract APIs (no
/// androidx.documentfile dependency): a tree file is materialized
/// into the cache first (same share_<millis>_<name> shape as
/// ShareHandler), then the existing File-based paths use it.
///
/// The picker UI itself stays in MainActivity: the
/// ActivityResultLauncher must be registered on the Activity, and
/// the pending reply belongs to the permission-result lifecycle.
/// This handler owns the intent, the tree walk, and the
/// copy / delete / persisted-grant operations.
///
/// P1-2: failures throw [ChannelFailure] instead of a silent null /
/// false; Dart maps each of these calls back to the same null /
/// false fallback as before.
class SafHandler(
    private val context: Context,
    private val runner: ChannelRunner,
    private val shareHandler: ShareHandler,
) {

    /// Dispatches the media_store methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    /// ("pickDownloadTree" is NOT here — the launcher lives in the
    /// Activity; see MainActivity.)
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "copyTreeFileToCache" -> {
                val treeUri = call.argument<String>("treeUri")?.let(Uri::parse)
                val relativePath = call.argument<String>("relativePath")
                if (treeUri == null || relativePath.isNullOrEmpty()) {
                    result.success(null)
                } else {
                    runner.runAsync(result, runner.ioExecutor, "saf_copy_failed") {
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
                    runner.runAsync(result, runner.lightExecutor, "saf_delete_failed") {
                        deleteTreeFile(treeUri, relativePath)
                    }
                }
            }
            "persistedTreeUris" -> {
                runner.runAsync(result, runner.lightExecutor, "persisted_tree_uris_failed") {
                    persistedTreeUris()
                }
            }
            else -> return false
        }
        return true
    }

    /// The ACTION_OPEN_DOCUMENT_TREE intent for the download folder,
    /// pre-positioned at Download/zlibx. EXTRA_INITIAL_URI is only a
    /// hint (ignored below API 26); the user can still navigate.
    fun treePickIntent(): Intent {
        val initial = try {
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                "primary:Download/zlibx",
            )
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "tree initial URI failed", e)
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

    /// Walk [relativePath] ('sub/Book.epub' segments) under the SAF
    /// tree [treeUri] and return the leaf document ID, or null when
    /// any segment is missing or is not a file. Only framework
    /// DocumentsContract queries — no extra dependency.
    private fun findTreeDocumentId(treeUri: Uri, relativePath: String): String? {
        var parentId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "SAF tree document ID failed", e)
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
            val mime = context.contentResolver.query(
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
            Log.w(NATIVE_TAG, "SAF leaf mime check failed", e)
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
            context.contentResolver.query(
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
            Log.w(NATIVE_TAG, "SAF child lookup failed", e)
            null
        }
    }

    /// Copy the tree file at [relativePath] into the app cache dir
    /// (same share_<millis>_<name> shape as ShareHandler) and
    /// return the temp file's absolute path. Throws [ChannelFailure]
    /// ("saf_copy_failed") on any failure.
    fun copyTreeFileToCache(treeUri: Uri, relativePath: String): String {
        // Same stale-temp cleanup as the share copy: the cache never
        // fills with orphaned materializations.
        shareHandler.cleanupStaleShareFiles()
        return try {
            val docId = findTreeDocumentId(treeUri, relativePath)
                ?: throw ChannelFailure("saf_copy_failed", "document not found")
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            val displayName = context.contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            val rawName = displayName?.takeIf { it.isNotBlank() }
                ?: relativePath.substringAfterLast('/').takeIf { it.isNotBlank() }
                ?: "shared_file"
            val file = File(context.cacheDir, shareTempFileName(rawName))
            context.contentResolver.openInputStream(docUri)?.use { inputStream ->
                file.outputStream().use { output ->
                    inputStream.copyTo(output)
                }
            } ?: throw ChannelFailure("saf_copy_failed", "input stream unavailable")
            file.absolutePath
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "SAF copy to cache failed", e)
            throw ChannelFailure("saf_copy_failed", e.javaClass.simpleName)
        }
    }

    /// Delete the tree file at [relativePath]. Throws
    /// [ChannelFailure] ("saf_delete_failed") when missing or when
    /// the delete fails (Dart reads it as false, as before).
    fun deleteTreeFile(treeUri: Uri, relativePath: String): Boolean {
        return try {
            val docId = findTreeDocumentId(treeUri, relativePath)
                ?: throw ChannelFailure("saf_delete_failed", "document not found")
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            DocumentsContract.deleteDocument(context.contentResolver, docUri)
        } catch (e: ChannelFailure) {
            throw e
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "SAF delete failed", e)
            throw ChannelFailure("saf_delete_failed", e.javaClass.simpleName)
        }
    }

    /// Tree URIs this app still holds a persisted read grant for, from
    /// the external-storage documents provider (used to re-adopt a
    /// grant after a clear-data wiped the stored URI string).
    /// Throws [ChannelFailure] ("persisted_tree_uris_failed") when
    /// the query itself fails (Dart reads it as "no grant", as before).
    fun persistedTreeUris(): List<String> {
        return try {
            context.contentResolver.persistedUriPermissions
                .filter {
                    it.isReadPermission &&
                        it.uri.authority == "com.android.externalstorage.documents"
                }
                .map { it.uri.toString() }
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "persisted tree URIs failed", e)
            throw ChannelFailure(
                "persisted_tree_uris_failed",
                e.javaClass.simpleName,
            )
        }
    }
}
