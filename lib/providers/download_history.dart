part of 'download_provider.dart';

/// Startup history load: reads persisted completed downloads and turns
/// each entry into a task. Owns the partial-download recovery too: an
/// in-flight download has no history row, so after a process death the
/// only trace on disk is the staged `.part` / `.meta` / pending
/// sidecar — recovery turns those back into paused tasks.
mixin _DownloadHistoryMixin on _DownloadPathsMixin {
  /// 启动恢复只跑一次（build() 会因 invalidate 重跑，notifier 实例
  /// 复用，实例旗标跨 invalidate 存活）。
  bool _recoveryDone = false;

  /// 封面回填同样每进程一次。
  bool _coverBackfillDone = false;

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
      // #143：旧条目没存来源，读回来是 null，下载页就不标。
      source: parseDownloadSource(data['source']),
      // #95：旧条目没存指定文件夹，读回来是 null，走分类模式默认。
      customSubfolder: data['customSubfolder']?.toString(),
    );
  }

  // ── 断点恢复：盘上残片 → paused 任务（2026-11-21 下载中断修复）──
  //
  // 下载中途进程死亡（划掉应用/系统回收），Dart 引擎随之消失，但
  // .part / .meta / pending 侧车都在暂存目录里——断点续传管线本身
  // 能接着跑（startDownload 内部按盘上字节自对账），缺的只是把书挂
  // 回下载页的那个任务。这里把残片按文件名还原成 paused 任务：下载
  // 页"进行中"出现条目 + 继续按钮，点了走既有 resumeDownload。

  /// 扫描暂存目录恢复残片任务。幂等（每进程一次）；与历史加载共用
  /// "按 id 合并、不覆盖已有"的合并纪律。
  Future<void> _recoverPartialDownloads() async {
    if (_recoveryDone) return;
    _recoveryDone = true;
    try {
      final dir = Directory(await _resolveSaveDir());
      final entries = await dir.list().toList();
      // 同一本书可能在盘上留下多种痕迹（.part 本体 / .part.meta 校验
      // 符 / .part.pending.json 侧车），按 base 去重。
      final bases = <String>{};
      for (final entity in entries) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final base = _stripPartialSuffixes(name);
        if (base != null) bases.add(base);
      }
      final recovered = <DownloadTask>[];
      for (final base in bases) {
        final task = await _recoveredTaskFor(dir, base);
        if (task == null) continue;
        if (state.any((t) => t.id == task.id)) continue;
        recovered.add(task);
      }
      if (recovered.isEmpty) return;
      final recoveredIds = recovered.map((t) => t.id).toSet();
      state = [
        ...state.where((t) => !recoveredIds.contains(t.id)),
        ...recovered,
      ];
      AppLog.report(
        'recovered ${recovered.length} partial download(s)',
        tag: 'download_provider',
      );
    } on Object catch (error) {
      logIgnored('download_recovery', error);
    }
  }

  /// 封面/作者回填（2026-11-21）：从残片恢复再续传完成的书，历史里
  /// 没有封面与作者（恢复任务本身没有）——下载页永远显示占位封面和
  /// "未知作者"。这里对"已完成 + 无封面 + z 站数字 id"的条目按标题
  /// 搜索一次，把作者/封面补进任务与历史记录。每进程一次、串行。
  Future<void> _backfillMissingCovers() async {
    if (_coverBackfillDone) return;
    _coverBackfillDone = true;
    final targets =
        state
            .where(
              (t) =>
                  t.status == DownloadStatus.completed &&
                  (t.book.cover == null || t.book.cover!.isEmpty) &&
                  t.book.id > 0 &&
                  t.book.title.isNotEmpty,
            )
            .toList();
    for (final task in targets) {
      final match = await _searchMatchBook(task.book);
      if (match == null ||
          match.cover == null ||
          match.cover!.isEmpty) {
        continue;
      }
      final enriched = task.book.copyWith(author: match.author, cover: match.cover);
      _updateTask(task.id, (t) => t.copyWith(book: enriched));
      final filePath = task.filePath;
      if (filePath != null && await MediaStoreFiles.exists(filePath)) {
        // 历史条目重写：标题保留原值（盘上文件名由它铸造），只补作
        // 者与封面；来源与指定文件夹原样带上，不丢（#143/#95）。
        await _storage.addToDownloadHistory(
          task.book.id.toString(),
          task.book.title,
          enriched.author,
          filePath,
          cover: enriched.cover,
          extension: task.book.extension,
          source: task.source?.name,
          customSubfolder: task.customSubfolder,
        );
      }
    }
  }

  /// 一个残片 base → paused 任务。优先读来源 sidecar
  /// （`<base>.part.download.json`，引擎每轮下载重写，含完整书身份
  /// 与外部直链）；缺席/解析失败退回文件名反解（z 书可恢复，外部书
  /// 不行——meta 里没有直链）。两侧都不认识 → null（不动它）。
  Future<DownloadTask?> _recoveredTaskFor(Directory dir, String base) async {
    final sidecar = File('${dir.path}/$base.part.download.json');
    if (await sidecar.exists()) {
      try {
        final decoded = jsonDecode(await sidecar.readAsString());
        if (decoded is Map<String, dynamic>) {
          final rawId = decoded['id'];
          final id = rawId is int ? rawId : int.tryParse('$rawId');
          if (id != null && id > 0) {
            return DownloadTask(
              id: '$id',
              book: Book(
                id: id,
                title: decoded['title'] as String? ?? 'Unknown',
                author: decoded['author'] as String?,
                cover: decoded['cover'] as String?,
                extension: decoded['extension'] as String?,
                hash: decoded['hash'] as String?,
              ),
              status: DownloadStatus.paused,
              presetUrl: decoded['presetUrl'] as String?,
              // #143：sidecar 里有来源就带上，恢复后继续下载也不丢。
              source: parseDownloadSource(decoded['source']),
              // #95：sidecar 里有指定文件夹就带上，恢复后继续下载
              // 落在同一个文件夹。
              customSubfolder: decoded['customSubfolder'] as String?,
            );
          }
        }
      } on Object catch (error) {
        logIgnored('download_recovery', error);
      }
    }
    final parsed = _parseSafeFileName(base);
    if (parsed == null) return null;
    return DownloadTask(
      id: '${parsed.$1}',
      book: Book(id: parsed.$1, title: parsed.$2, extension: parsed.$3),
      status: DownloadStatus.paused,
    );
  }

  /// `<name>.part.pending.json` / `<name>.part.meta` / `<name>.part`
  /// → `<name>`；其他形态返回 null（用户自放文件不动）。
  static String? _stripPartialSuffixes(String name) =>
      stripPartialSuffixes(name);

  /// 反解 `_buildSafeFileName` 的产物 `<安全标题> - <数字 id>.<扩展名>`
  /// → (id, title, extension)。标题里也可能含 " - "，贪婪匹配天然锚
  /// 定最后一组 ` - 数字.扩展名`。id 非正或解析不出 → null。
  static (int, String, String)? _parseSafeFileName(String base) =>
      parseSafeFileName(base);
}

/// 库级纯函数：历史记录 / sidecar 里存的来源名（BookSource.name）
/// → BookSource；缺失或不认识 → null（旧条目没存，不标）。
BookSource? parseDownloadSource(Object? value) {
  final name = value?.toString();
  if (name == null || name.isEmpty) return null;
  for (final source in BookSource.values) {
    if (source.name == name) return source;
  }
  return null;
}

/// 库级纯函数（测试直接 import download_provider.dart 调用）：
/// `<name>.part.download.json`（来源 sidecar，优先级最高）/
/// `<name>.part.pending.json` / `<name>.part.meta` / `<name>.part`
/// → `<name>`；其他形态返回 null（用户自放文件不动）。
String? stripPartialSuffixes(String name) {
  for (final suffix in const [
    '.part.download.json',
    '.part.pending.json',
    '.part.meta',
    '.part',
  ]) {
    if (name.endsWith(suffix)) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  return null;
}

/// 库级纯函数：反解 `_buildSafeFileName` 的产物。见 mixin 内同名
/// 方法文档。
(int, String, String)? parseSafeFileName(String base) {
  final match = RegExp(r'^(.*) - (\d+)\.([A-Za-z0-9]+)$').firstMatch(base);
  if (match == null) return null;
  final id = int.tryParse(match.group(2)!);
  if (id == null || id <= 0) return null;
  return (id, match.group(1)!, match.group(3)!.toLowerCase());
}
