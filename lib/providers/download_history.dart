part of 'download_provider.dart';

/// Startup history load: reads persisted completed downloads and turns
/// each entry into a task.
mixin _DownloadHistoryMixin on _DownloadNotifierBase {
  /// Load completed downloads from storage on app startup
  Future<void> _loadDownloadHistory() async {
    try {
      final history = await _storage.getDownloadHistory();
      // Entries are independent, so they load in parallel; Future.wait
      // keeps the result order, so the task order matches the old
      // serial loop exactly.
      // Bounded batches: every entry costs a MediaStore platform-channel
      // call, and an unbounded fan-out over a long history floods the
      // channel and the IO worker at startup. Order is preserved.
      const batchSize = 8;
      final entries = history.entries.toList();
      final tasks = <DownloadTask?>[];
      for (var i = 0; i < entries.length; i += batchSize) {
        final batch = entries.skip(i).take(batchSize);
        tasks.addAll(
          await Future.wait(
            batch.map(
              (entry) => _taskFromHistoryEntry(
                entry.key,
                entry.value as Map<String, dynamic>,
              ),
            ),
          ),
        );
      }
      final loadedTasks = [
        for (final task in tasks)
          if (task != null) task,
      ];

      // Merge by id instead of overwriting: the user may already have
      // started a new download while this async history load was in
      // flight — `state = loadedTasks` would erase it and its progress
      // bar would silently disappear (the download keeps running but
      // _updateTask can no longer find the row).
      if (loadedTasks.isNotEmpty) {
        final loadedIds = loadedTasks.map((t) => t.id).toSet();
        state = [
          ...state.where((t) => !loadedIds.contains(t.id)),
          ...loadedTasks,
        ];
      }
    } catch (e) {
      // History failure should not break new downloads.
      AppLog.report(
        'Could not load download history: ${e.runtimeType}',
        tag: 'download_provider',
      );
    }
  }

  /// Builds one history task from its stored entry, or null when the
  /// entry has no file path. Kept separate so [_loadDownloadHistory]
  /// can load entries in parallel with [Future.wait]; within one entry
  /// the order is unchanged (existence is checked before measuring the
  /// file, and the length is only measured for a non-content URI that
  /// exists).
  Future<DownloadTask?> _taskFromHistoryEntry(
    String bookId,
    Map<String, dynamic> data,
  ) async {
    final filePath = data['filePath'] as String?;
    if (filePath == null) return null;
    final file = File(filePath);
    final fileExists = await MediaStoreFiles.exists(filePath);

    // Create a minimal Book object from stored data
    final book = Book(
      id: int.tryParse(bookId) ?? 0,
      title: data['title'] as String? ?? 'Unknown',
      author: data['author'] as String?,
      cover: data['cover'] as String?,
      extension: data['extension'] as String?,
    );

    return DownloadTask(
      id: bookId,
      book: book,
      progress: 1.0,
      status: fileExists ? DownloadStatus.completed : DownloadStatus.error,
      filePath: filePath,
      error: fileExists ? null : 'File not found',
      downloadedAt: DateTime.tryParse(data['downloadTime']?.toString() ?? ''),
      // MediaStore content URIs have no local File to measure,
      // so the size stays unknown for history-loaded entries.
      fileSize: fileExists && !MediaStoreFiles.isContentUri(filePath)
          ? await file.length()
          : null,
      missingFile: !fileExists,
    );
  }
}
