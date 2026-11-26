// SAF folder access: read books in Download/zlibx/ that a clear-data
// orphaned (their MediaStore rows lost owner_package_name, so the app
// can stat the files but open() throws EACCES). Instead of
// MANAGE_EXTERNAL_STORAGE (all-files access — rejected by the user),
// the user picks the Download/zlibx folder once in the system picker
// and the grant is persisted; only that folder is ever accessed.
//
// An orphaned file is read by materializing it into the app cache
// first (copyTreeFileToCache on the native side), then the existing
// File-based paths (open / share / web streaming) use the cache copy.
// A file the app can already open is never copied.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'hive_service.dart';

class SafFolderAccess {
  static const _channel = MethodChannel('zlibx/media_store');

  /// Hive settings-box key holding the picked tree URI string.
  static const _kSafTreeUri = 'safTreeUri';

  /// Test seam: tests inject a tree URI instead of reading Hive, and a
  /// tree root instead of asking path_provider. Null in production.
  /// (The seam also doubles as the in-memory copy of the stored URI:
  /// [_storeTreeUri] sets it, so a stored grant is visible to this
  /// process without another Hive read.)
  @visibleForTesting
  static String? treeUriForTesting;

  @visibleForTesting
  static String? treeRootForTesting;

  /// Test seam: the Android-only methods below return early on other
  /// platforms. Tests set [forceAndroidForTesting] to drive the
  /// platform-channel path on the host (same pattern as
  /// MediaStoreFiles.forceAndroidForTesting).
  @visibleForTesting
  static bool forceAndroidForTesting = false;

  static bool get _onAndroid => forceAndroidForTesting || Platform.isAndroid;

  /// The stored tree URI string, or null. Reads the Hive settings box
  /// (opened before the first frame); a closed box (tests) reads as
  /// no stored URI instead of throwing.
  String? get _storedTreeUri {
    if (treeUriForTesting != null) return treeUriForTesting;
    try {
      return HiveService.settingsBox.get(_kSafTreeUri) as String?;
    } on Object {
      return null;
    }
  }

  Future<void> _storeTreeUri(String uri) async {
    treeUriForTesting = uri;
    try {
      await HiveService.settingsBox.put(_kSafTreeUri, uri);
    } on Object {
      // Best-effort: the in-memory copy above is enough for this
      // process (a closed box in tests).
    }
  }

  /// Whether a tree grant is held: a stored URI, or a persisted grant
  /// re-adopted from the system (a clear-data wipes the stored URI
  /// string but not the grant itself).
  Future<bool> get hasGrant async {
    if (_storedTreeUri != null) return true;
    if (!_onAndroid) return false;
    try {
      final persisted =
          await _channel.invokeMethod<List<dynamic>>('persistedTreeUris');
      for (final uri in persisted?.whereType<String>() ?? const <String>[]) {
        if (_isDownloadTree(uri)) {
          await _storeTreeUri(uri);
          return true;
        }
      }
    } on PlatformException {
      return false;
    }
    return false;
  }

  /// A persisted tree URI counts when its document ID is under
  /// Download (the picker starts at Download/zlibx).
  bool _isDownloadTree(String uri) {
    final last = uri.split('/').last;
    if (last.isEmpty) return false;
    try {
      return Uri.decodeComponent(last).startsWith('primary:Download');
    } on Object {
      return false;
    }
  }

  /// Open the system folder picker at Download/zlibx. Returns the
  /// picked tree URI string (and stores it), or null when cancelled
  /// or the pick fails. Non-Android returns null.
  Future<String?> pickFolder() async {
    if (!_onAndroid) return null;
    try {
      final uri = await _channel.invokeMethod<String>('pickDownloadTree');
      if (uri == null || uri.isEmpty) return null;
      await _storeTreeUri(uri);
      return uri;
    } on PlatformException {
      return null;
    }
  }

  /// Copy the file at [realPath] out of the granted folder into the
  /// app cache and return the cache path, or null when there is no
  /// grant, the file is outside the folder, or the copy fails.
  Future<String?> materialize(String realPath) async {
    if (!_onAndroid) return null;
    var treeUri = _storedTreeUri;
    if (treeUri == null) {
      if (!await hasGrant) return null;
      treeUri = _storedTreeUri;
      if (treeUri == null) return null;
    }
    final relative = await _relativePath(realPath);
    if (relative == null) return null;
    try {
      final path = await _channel.invokeMethod<String>(
        'copyTreeFileToCache',
        <String, Object>{'treeUri': treeUri, 'relativePath': relative},
      );
      return (path != null && path.isNotEmpty) ? path : null;
    } on PlatformException {
      return null;
    }
  }

  /// Delete the file at [realPath] through the granted folder. False
  /// when there is no grant, the file is outside the folder, or the
  /// delete fails.
  Future<bool> deleteTreeFile(String realPath) async {
    if (!_onAndroid) return false;
    var treeUri = _storedTreeUri;
    if (treeUri == null) {
      if (!await hasGrant) return false;
      treeUri = _storedTreeUri;
      if (treeUri == null) return false;
    }
    final relative = await _relativePath(realPath);
    if (relative == null) return false;
    try {
      return await _channel.invokeMethod<bool>(
        'deleteTreeFile',
        <String, Object>{'treeUri': treeUri, 'relativePath': relative},
      ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Probe whether [path] can actually be opened — the check stat
  /// cannot do: an orphaned file exists (stat passes) but open throws.
  static Future<bool> canOpen(String path) async {
    try {
      final file = await File(path).open();
      await file.close();
      return true;
    } on Object {
      return false;
    }
  }

  /// The single entry point the read paths use: content:// URIs pass
  /// through (existing flows handle them); a plain path that opens
  /// passes through; anything else is materialized through the SAF
  /// grant (null when that fails too).
  Future<String?> readablePath(String location) async {
    if (_isContentUri(location)) return location;
    if (await canOpen(location)) return location;
    return materialize(location);
  }

  /// Same content:// check as MediaStoreFiles.isContentUri, kept local
  /// so this file does not import media_store.dart (which imports this
  /// file — a cycle).
  static bool _isContentUri(String location) =>
      location.startsWith('content://');

  /// The granted folder's real path (`<external>/Download/zlibx`),
  /// or null when it cannot be determined. Same
  /// getExternalStorageDirectory + strip-`/Android/data/` logic as
  /// the orphan relink in download_history.dart (not importable —
  /// it is a private method there).
  Future<String?> _treeRoot() async {
    if (treeRootForTesting != null) return treeRootForTesting;
    try {
      final appExternal = await getExternalStorageDirectory();
      if (appExternal == null) return null;
      const marker = '/Android/data/';
      final index = appExternal.path.indexOf(marker);
      if (index <= 0) return null;
      return '${appExternal.path.substring(0, index)}Download/zlibx';
    } on Object {
      return null;
    }
  }

  /// [realPath] relative to the granted folder ('sub/Book.epub'), or
  /// null when it is outside the folder.
  Future<String?> _relativePath(String realPath) async {
    final root = await _treeRoot();
    if (root == null) return null;
    final prefix = root.endsWith('/') ? root : '$root/';
    if (!realPath.startsWith(prefix)) return null;
    final relative = realPath.substring(prefix.length);
    if (relative.isEmpty) return null;
    if (relative.split('/').any((s) => s == '.' || s == '..')) {
      return null;
    }
    return relative;
  }
}
