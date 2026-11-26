// MediaStore bridge: publish finished downloads into the public
// Downloads/zlibx folder (Android 10+), and handle the content://
// locations that come back from it (open / exists / delete / share).
//
// The download engine still writes to the app-specific dir first;
// DownloadNotifier publishes the finished file and records the
// content URI. Old history entries keep plain file paths and keep
// working — every helper below routes on the `content://` prefix.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_log.dart';
import 'saf_folder_access.dart';


class MediaStoreFiles {
  static const _channel = MethodChannel('zlibx/media_store');

  /// Test seam: the Android-only methods below return early on other
  /// platforms. Tests set [forceAndroidForTesting] to drive the
  /// platform-channel path on the host; production always reads
  /// [Platform.isAndroid], so behaviour is unchanged.
  @visibleForTesting
  static bool forceAndroidForTesting = false;

  /// True on Android, or when a test forces the Android path.
  static bool get _onAndroid => forceAndroidForTesting || Platform.isAndroid;

  static bool isContentUri(String location) =>
      location.startsWith('content://');

  /// MIME type for a book extension (used for the MediaStore insert).
  static String mimeTypeForExtension(String? extension) {
    switch ((extension ?? '').toLowerCase()) {
      case 'epub':
        return 'application/epub+zip';
      case 'pdf':
        return 'application/pdf';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw3':
        return 'application/vnd.amazon.ebook';
      case 'azw':
        return 'application/vnd.amazon.mobi8-ebook';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'cbz':
        return 'application/x-cbz';
      case 'cbr':
        return 'application/x-cbr';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Copy [sourcePath] into the public Downloads/zlibx folder via
  /// MediaStore (Android 10+ only). Returns the content URI string,
  /// or null when MediaStore is unavailable or the publish fails —
  /// the caller then keeps the app-specific file and reports success
  /// with that location. [subfolder] is the organize-mode subfolder
  /// under Download/zlibx (null = flat).
  static Future<String?> publishToDownloads({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String? subfolder,
  }) async {
    if (!_onAndroid) return null;
    try {
      final uri = await _channel.invokeMethod<String>(
        'publishToDownloads',
        <String, Object>{
          'sourcePath': sourcePath,
          'displayName': displayName,
          'mimeType': mimeType,
          if (subfolder != null) 'subfolder': subfolder,
        },
      );
      return (uri != null && uri.isNotEmpty) ? uri : null;
    } on PlatformException catch (e) {
      AppLog.report(
        'MediaStore publish failed: ${e.code} ${e.message}',
        tag: 'media_store',
      );
      return null;
    }
  }

  /// Create a pending MediaStore entry in the public Downloads/zlibx
  /// folder (Android 10+ only), to be filled by [writePendingChunk]
  /// and published by [finishPendingDownload]. Returns the content
  /// URI string, or null when unavailable — the caller then falls
  /// back to the staged .part flow. [subfolder] is the organize-mode
  /// subfolder under Download/zlibx (null = flat).
  static Future<String?> createPendingDownload({
    required String displayName,
    required String mimeType,
    String? subfolder,
  }) async {
    if (!_onAndroid) return null;
    try {
      final uri = await _channel.invokeMethod<String>(
        'createPendingDownload',
        <String, Object>{
          'displayName': displayName,
          'mimeType': mimeType,
          if (subfolder != null) 'subfolder': subfolder,
        },
      );
      return (uri != null && uri.isNotEmpty) ? uri : null;
    } on PlatformException catch (e) {
      AppLog.report(
        'MediaStore createPendingDownload failed: ${e.code} ${e.message}',
        tag: 'media_store',
      );
      return null;
    }
  }

  /// Append one batch of bytes to a pending entry. [bytes] must be a
  /// contiguous block (the writer coalesces to 256 KB before calling).
  static Future<bool> writePendingChunk(String uri, List<int> bytes) async {
    if (!_onAndroid) return false;
    try {
      // Uint8List crosses the channel as a byte[]; a plain List<int>
      // would arrive as ArrayList<Integer> on the Kotlin side. Reuse
      // the buffer when it already is one (no extra 256 KB copy).
      final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      return await _channel.invokeMethod<bool>(
            'writePendingChunk',
            <String, Object>{'uri': uri, 'bytes': payload},
          ) ??
          false;
    } on PlatformException catch (e) {
      // L4: the cause used to be dropped here (a bare `return false`),
      // so a storage failure surfaced only as a generic "pending write
      // failed" with no code. Log it (same pattern as publish/create
      // above) and let it through — the writer's catch records it in
      // _writeError, code included.
      AppLog.report(
        'MediaStore writePendingChunk failed: ${e.code} ${e.message}',
        tag: 'media_store',
      );
      rethrow;
    }
  }

  /// Publish a pending entry (clear IS_PENDING). False on failure.
  static Future<bool> finishPendingDownload(String uri) async {
    if (!_onAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'finishPendingDownload',
            <String, Object>{'uri': uri},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Delete a pending entry. False on failure.
  static Future<bool> abortPendingDownload(String uri) async {
    if (!_onAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'abortPendingDownload',
            <String, Object>{'uri': uri},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Actual byte size of a pending entry, read from its file
  /// descriptor. Used on resume to reconcile the persisted byte count
  /// (see PendingUriWriter.resume). Returns -1 when the size cannot be
  /// determined (non-Android, entry gone, platform error).
  static Future<int> pendingEntrySize(String uri) async {
    if (!_onAndroid) return -1;
    try {
      return await _channel.invokeMethod<int>(
            'pendingEntrySize',
            <String, Object>{'uri': uri},
          ) ??
          -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Existence check that understands both plain paths and the
  /// content:// URIs publishToDownloads returns.
  ///
  /// Fallback: a stored content URI can stop opening (stale row) while
  /// the file itself is still on disk — the Web service reads files by
  /// real path (realPath + File), so when the ContentResolver check
  /// fails, resolve the real path and stat the file before giving up.
  /// Records recovered this way read as present again (and re-enter
  /// the Web snapshot) instead of dropping to error/missing.
  static Future<bool> exists(String location) async {
    if (isContentUri(location)) {
      if (!_onAndroid) return false;
      try {
        final found = await _channel.invokeMethod<bool>(
              'contentExists',
              <String, Object>{'uri': location},
            ) ??
            false;
        if (found) return true;
      } on PlatformException {
        return false;
      }
      final real = await realPath(location);
      if (real != null && real.isNotEmpty) {
        return File(real).exists();
      }
      return false;
    }
    return File(location).exists();
  }

  /// Open with the system default app. Content URIs go through the
  /// platform channel (ACTION_VIEW with a read grant); plain paths
  /// keep using OpenFilex as before — except an orphaned file the app
  /// cannot open by path is materialized through the SAF folder grant
  /// first (see [SafFolderAccess.readablePath]).
  static Future<bool> open(String location) async {
    if (isContentUri(location)) {
      if (!_onAndroid) return false;
      try {
        return await _channel.invokeMethod<bool>(
              'openContent',
              <String, Object>{'uri': location},
            ) ??
            false;
      } on PlatformException {
        return false;
      }
    }
    final readable = await SafFolderAccess().readablePath(location);
    if (readable == null) return false;
    final result = await OpenFilex.open(readable);
    return result.type == ResultType.done;
  }

  /// Delete. Content URIs go through ContentResolver; plain paths
  /// are deleted as files, as before — except an orphaned file, which
  /// cannot be deleted by path either (same EACCES as open): it is
  /// deleted through the SAF folder grant instead.
  static Future<bool> delete(String location) async {
    if (isContentUri(location)) {
      if (!_onAndroid) return false;
      try {
        return await _channel.invokeMethod<bool>(
              'deleteContent',
              <String, Object>{'uri': location},
            ) ??
            false;
      } on PlatformException {
        return false;
      }
    }
    final file = File(location);
    if (await file.exists()) {
      try {
        await file.delete();
        return true;
      } on Object {
        return SafFolderAccess().deleteTreeFile(location);
      }
    }
    return false;
  }

  /// Test seam: tests point the share-cache copy at a temp dir
  /// instead of the real cache dir. Null in production, where
  /// [getTemporaryDirectory] is used.
  @visibleForTesting
  static Directory? shareCacheDirForTesting;

  /// Resolve a location to a plain file path share_plus can hand to
  /// the system share sheet.
  ///
  /// content:// URIs are copied to a temp file in the app cache dir
  /// first (share_plus cannot share a content URI directly).
  ///
  /// Plain paths (2026-11-26): a relinked orphan — or any old history
  /// entry — lives at a real path under Download/zlibx, and sharing
  /// that path fails on device ("无法分享文件"): the app's share flow
  /// was built around handing share_plus a cache file, so a real path
  /// outside the app cache is copied into the cache first (same shape
  /// as the content-URI flow above); a path already in the cache is
  /// handed over as-is. Returns null when the copy fails.
  static Future<String?> shareablePath(String location) async {
    if (isContentUri(location)) {
      if (!_onAndroid) return null;
      try {
        final path = await _channel.invokeMethod<String>(
          'copyContentToCache',
          <String, Object>{'uri': location},
        );
        return (path != null && path.isNotEmpty) ? path : null;
      } on PlatformException {
        return null;
      }
    }
    if (!_onAndroid) return location;
    try {
      final cacheDir =
          shareCacheDirForTesting ?? await getTemporaryDirectory();
      if (location == cacheDir.path ||
          p.isWithin(cacheDir.path, location)) {
        return location;
      }
      // An orphaned file cannot be opened by path, so the copy below
      // would throw: resolve it through the SAF folder grant first
      // (materialized into the cache). A file that opens directly is
      // returned unchanged, so this is a no-op for normal files; a
      // materialized path is already in the cache and is handed over
      // as-is.
      final source = await SafFolderAccess().readablePath(location);
      if (source == null) return null;
      if (source == cacheDir.path || p.isWithin(cacheDir.path, source)) {
        return source;
      }
      final dest = File(p.join(cacheDir.path, _shareCacheName(location)));
      await File(source).copy(dest.path);
      return dest.path;
    } on Object {
      return null;
    }
  }

  /// Cache file name for a plain path being shared: `share_` + the
  /// source base name, with the stem cut to 120 UTF-8 bytes and the
  /// extension to 16 (same caps as the Kotlin copyContentToCache —
  /// a long CJK title would otherwise overflow Android's 255-byte
  /// file-name cap and the copy would throw). The base name already
  /// carries the book id, so no timestamp prefix is needed.
  static String _shareCacheName(String location) {
    final base = p.basename(location);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 && dot < base.length - 1 ? base.substring(dot) : '';
    return 'share_${_truncateUtf8(stem, 120)}${_truncateUtf8(ext, 16)}';
  }

  /// [name] cut to at most [maxBytes] UTF-8 bytes, only on character
  /// boundaries (a cut mid-character would leave an invalid name).
  static String _truncateUtf8(String name, int maxBytes) {
    var bytes = 0;
    final out = StringBuffer();
    for (final rune in name.runes) {
      final char = String.fromCharCode(rune);
      final charBytes = utf8.encode(char).length;
      if (bytes + charBytes > maxBytes) break;
      bytes += charBytes;
      out.write(char);
    }
    return out.toString();
  }

  /// Resolve a location to the real filesystem path, for display and
  /// copy (#123 follow-up: the stored content:// URI is not a path a
  /// file manager can search for). Plain paths pass through unchanged;
  /// content:// URIs are resolved through MediaStore (RELATIVE_PATH +
  /// DISPLAY_NAME under the external storage dir). Returns null when
  /// it cannot be resolved — the caller falls back to the stored
  /// location.
  static Future<String?> realPath(String location) async {
    if (!isContentUri(location)) return location;
    if (!_onAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>(
        'realPathForContent',
        <String, Object>{'uri': location},
      );
      return (path != null && path.isNotEmpty) ? path : null;
    } on PlatformException {
      return null;
    }
  }
}
