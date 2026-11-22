part of 'download_provider.dart';

/// Save-directory and filename helpers shared by the engine and the
/// existence check.
mixin _DownloadPathsMixin on _DownloadNotifierBase {
  /// 下载保存目录（各平台统一入口，下载与「文件已存在」判断共用）。
  Future<String> _resolveSaveDir() async {
    if (Platform.isAndroid) return (await _androidDownloadDir()).path;

    final customPath = await _storage.getDownloadPath();
    if (customPath != null && customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      return customPath;
    }
    return (await getApplicationDocumentsDirectory()).path;
  }

  /// Android 应用专属外部目录 `<...>/Android/data/<pkg>/files/Olib`。
  ///
  /// 这只是下载的暂存目录：下完后经 MediaStore 发布到公共
  /// `Download/zlibx`，历史记录记的是发布后的 content:// 位置。
  /// 专属目录无需任何存储权限，卸载时随应用一起清除；历史记录里
  /// 的旧路径仍可打开。
  Future<Directory> _androidDownloadDir() async {
    // 形如 /storage/emulated/<user>/Android/data/<pkg>/files
    final appExternal = await getExternalStorageDirectory();
    if (appExternal == null) return getApplicationDocumentsDirectory();

    final dir = Directory('${appExternal.path}/Olib');
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } on FileSystemException catch (e) {
      AppLog.report(
        'App download dir unavailable, fallback: $e',
        tag: 'download_provider',
      );
      return appExternal;
    }
  }

  /// Check if file already exists for a book
  /// Returns the file path if exists, null otherwise
  Future<String?> checkFileExists(Book book) async {
    // The history lookup and the save-path build do not depend on each
    // other, so they run together; existence is then checked in the
    // same priority order as before (history first, then save path).
    final results = await Future.wait([
      _storage.getDownloadedFilePath(book.id.toString()),
      _buildSavePath(book),
    ]);
    final historyPath = results[0];
    final savePath = results[1];
    if (historyPath != null && await MediaStoreFiles.exists(historyPath)) {
      return historyPath;
    }

    // Also check if file exists in download directory (may have been downloaded elsewhere)
    if (savePath != null) {
      final file = File(savePath);
      if (await file.exists()) {
        return savePath;
      }
    }

    return null;
  }

  /// Build a safe filename for a book
  String _buildSafeFileName(Book book) {
    String safeTitle = book.title
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '')
        .trim();

    if (safeTitle.isEmpty) {
      safeTitle = 'book_${book.id}';
      if (book.author != null && book.author!.isNotEmpty) {
        final safeAuthor = book.author!
            .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '')
            .trim();
        if (safeAuthor.isNotEmpty) {
          safeTitle = '$safeAuthor - $safeTitle';
        }
      }
    }

    final cleanExtension = (book.extension ?? 'epub')
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toLowerCase();
    final ext = cleanExtension.isEmpty ? 'epub' : cleanExtension;
    // Android caps a filename at 255 bytes; keep the whole
    // 'title - id.ext' within maxFileNameBytes so a long (e.g.
    // Chinese) title can never fail the write.
    final suffix = ' - ${book.id}.$ext';
    safeTitle = truncateUtf8ByBytes(
      safeTitle,
      maxFileNameBytes - utf8.encode(suffix).length,
    );
    return '$safeTitle$suffix';
  }

  /// Subfolder for [book] under the download directory, from the
  /// user's organize mode. Null when organizing is off. Only new
  /// downloads use it — already-downloaded files stay where they are,
  /// and open/share resolve through the stored path, never by
  /// re-deriving it. The name is sanitized so it can never escape the
  /// download directory ('..', separators and control characters are
  /// stripped); a book with no usable author/category falls back to
  /// the mode's "unknown" folder (hardcoded Chinese: the engine has
  /// no BuildContext to localize through, and these are edge cases).
  String? _downloadSubfolder(Book book) {
    final mode = ref.read(downloadOrganizeModeProvider);
    final String? raw;
    final String fallback;
    switch (mode) {
      case DownloadOrganizeMode.off:
        return null;
      case DownloadOrganizeMode.author:
        raw = book.author;
        fallback = '未知作者';
      case DownloadOrganizeMode.category:
        // No firstOrNull in this codebase (avoids package:collection):
        // split(',') on a non-empty string always yields >= 1 part.
        final parts = book.categories?.split(',');
        raw = (parts != null && parts.isNotEmpty)
            ? parts.first.trim()
            : null;
        fallback = '未分类';
    }
    final name = _sanitizeFolderName(raw ?? '');
    return name.isEmpty ? fallback : name;
  }

  /// Strip anything that cannot appear in a folder name (separators,
  /// control characters, a name made only of dots), and cap the length
  /// so the full path stays well inside filesystem limits.
  String _sanitizeFolderName(String raw) {
    var name = raw
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '')
        .trim();
    if (RegExp(r'^\.+$').hasMatch(name)) name = '';
    if (name.length > 100) name = name.substring(0, 100).trim();
    return name;
  }

  /// Build save path for a book (for non-MediaStore platforms)
  Future<String?> _buildSavePath(Book book) async {
    try {
      final baseDir = await _resolveSaveDir();
      final subfolder = _downloadSubfolder(book);
      if (subfolder == null) return '$baseDir/${_buildSafeFileName(book)}';
      final dir = Directory('$baseDir/$subfolder');
      if (!await dir.exists()) await dir.create(recursive: true);
      return '${dir.path}/${_buildSafeFileName(book)}';
    } catch (e) {
      return null;
    }
  }
}
