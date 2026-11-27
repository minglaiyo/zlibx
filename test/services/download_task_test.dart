// Tests for the download state machine: DownloadTask.canRetry /
// copyWith (pure) and the DownloadNotifier transitions that do not
// need the network (history load, markMissingFile, removeTask,
// cancelDownload's token guard).
//
// The notifier only touches StorageService in these paths, so the
// container overrides storageServiceProvider with an in-memory fake.
// The real API provider is never read here (no download is started).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/services/storage_service.dart';

/// In-memory stand-in for StorageService's download-history methods.
class _FakeStorage extends StorageService {
  Map<String, dynamic> history = <String, dynamic>{};
  final List<String> removedIds = <String>[];

  @override
  Future<Map<String, dynamic>> getDownloadHistory() async => history;

  @override
  Future<void> removeFromDownloadHistory(String bookId) async {
    removedIds.add(bookId);
    history.remove(bookId);
  }
}

void main() {
  const book = Book(id: 7, title: 'Test Book', hash: 'abc123');

  group('DownloadTask.canRetry', () {
    test('error and cancelled tasks with a usable hash can retry', () {
      expect(
        const DownloadTask(id: '7', book: book, status: DownloadStatus.error)
            .canRetry,
        isTrue,
      );
      expect(
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.cancelled,
        ).canRetry,
        isTrue,
      );
    });

    test('pending / downloading / completed tasks cannot retry', () {
      for (final status in <DownloadStatus>[
        DownloadStatus.pending,
        DownloadStatus.downloading,
        DownloadStatus.completed,
      ]) {
        expect(
          DownloadTask(id: '7', book: book, status: status).canRetry,
          isFalse,
          reason: '$status',
        );
      }
    });

    test('needsFreshLink and missingFile block retry', () {
      expect(
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.error,
          needsFreshLink: true,
        ).canRetry,
        isFalse,
      );
      expect(
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.error,
          missingFile: true,
        ).canRetry,
        isFalse,
      );
    });

    test('a task without a usable book id / hash cannot retry', () {
      expect(
        const DownloadTask(
          id: '0',
          book: Book(id: 0, title: 'T', hash: 'abc'),
          status: DownloadStatus.error,
        ).canRetry,
        isFalse,
      );
      expect(
        const DownloadTask(
          id: '7',
          book: Book(id: 7, title: 'T'),
          status: DownloadStatus.error,
        ).canRetry,
        isFalse,
      );
      expect(
        const DownloadTask(
          id: '7',
          book: Book(id: 7, title: 'T', hash: ''),
          status: DownloadStatus.error,
        ).canRetry,
        isFalse,
      );
    });
  });

  group('DownloadTask.copyWith', () {
    test('overrides only the given fields', () {
      const task = DownloadTask(
        id: '7',
        book: book,
        progress: 0.42,
        status: DownloadStatus.downloading,
        filePath: '/tmp/book.epub',
        fileSize: 12345,
      );
      final updated = task.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
      );
      expect(updated.id, '7');
      expect(updated.book, book);
      expect(updated.status, DownloadStatus.completed);
      expect(updated.progress, 1.0);
      expect(updated.filePath, '/tmp/book.epub');
      expect(updated.fileSize, 12345);
      expect(updated.error, isNull);
      expect(updated.quotaExceeded, isFalse);
    });

    test('#95/#143：来源与指定文件夹在 copyWith 里不丢', () {
      const task = DownloadTask(
        id: '7',
        book: book,
        status: DownloadStatus.downloading,
        source: BookSource.libgen,
        customSubfolder: '小说',
        presetUrl: 'https://example.com/primary',
        fallbackUrls: ['https://example.com/mirror'],
      );
      // 状态推进（下载中 → 已完成）只改状态与进度，来源与文件夹保留。
      final updated = task.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
      );
      expect(updated.source, BookSource.libgen);
      expect(updated.customSubfolder, '小说');
      expect(updated.presetUrl, 'https://example.com/primary');
      expect(updated.fallbackUrls, ['https://example.com/mirror']);
      // 显式改指定文件夹：只改这一个字段。
      final moved = task.copyWith(customSubfolder: '科幻');
      expect(moved.customSubfolder, '科幻');
      expect(moved.source, BookSource.libgen);
    });
  });

  group('downloadNotificationSummary', () {
    test('single task keeps the existing text', () {
      final summary = downloadNotificationSummary([
        DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.downloading,
          progress: 0.42,
        ),
      ]);
      expect(summary.count, 1);
      expect(summary.percent, 42);
      expect(summary.text, '下载中 42%');
    });

    test('concurrent tasks use one stable aggregate', () {
      final summary = downloadNotificationSummary([
        DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.downloading,
          progress: 0.2,
        ),
        DownloadTask(
          id: '8',
          book: book,
          status: DownloadStatus.pending,
          progress: 0.6,
        ),
        DownloadTask(
          id: '9',
          book: book,
          status: DownloadStatus.completed,
          progress: 1,
        ),
      ]);
      expect(summary.count, 2);
      expect(summary.percent, 40);
      expect(summary.text, '2 个任务 · 下载中 40%');
    });

    test('no active task produces no notification progress', () {
      final summary = downloadNotificationSummary([
        DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.paused,
          progress: 0.5,
        ),
      ]);
      expect(summary.count, 0);
      expect(summary.text, '下载中…');
    });
  });

  group('DownloadNotifier', () {
    late Directory tempDir;
    late _FakeStorage storage;
    late ProviderContainer container;
    late DownloadNotifier notifier;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('download_task_');
      storage = _FakeStorage();
      container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      notifier = container.read(downloadProvider.notifier);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('build loads an empty history as no tasks', () async {
      await notifier.ready;
      expect(container.read(downloadProvider), isEmpty);
    });

    test('history load restores completed tasks and marks missing ones error',
        () async {
      final existing = File('${tempDir.path}/kept.epub')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      storage.history = <String, dynamic>{
        '7': <String, dynamic>{
          'title': 'Kept',
          'author': 'A',
          'filePath': existing.path,
          'cover': null,
          'extension': 'epub',
        },
        '8': <String, dynamic>{
          'title': 'Gone',
          'author': 'B',
          'filePath': '${tempDir.path}/gone.epub',
          'cover': null,
          'extension': 'epub',
        },
      };
      // A fresh container so build() sees the populated history.
      final fresh = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(fresh.dispose);
      final freshNotifier = fresh.read(downloadProvider.notifier);
      await freshNotifier.ready;
      final tasks = fresh.read(downloadProvider);
      expect(tasks, hasLength(2));
      final kept = tasks.firstWhere((t) => t.id == '7');
      expect(kept.status, DownloadStatus.completed);
      expect(kept.progress, 1.0);
      final gone = tasks.firstWhere((t) => t.id == '8');
      expect(gone.status, DownloadStatus.error);
    });

    test('markMissingFile flips a task to error with the missing flag',
        () async {
      await notifier.ready;
      notifier.state = <DownloadTask>[
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.completed,
          progress: 1.0,
        ),
      ];
      notifier.markMissingFile('7');
      final task = container.read(downloadProvider).single;
      expect(task.status, DownloadStatus.error);
      expect(task.missingFile, isTrue);
      expect(task.error, 'File not found');
      expect(task.canRetry, isFalse);
    });

    test('markMissingFile on an unknown id is a no-op', () async {
      await notifier.ready;
      notifier.state = <DownloadTask>[
        const DownloadTask(id: '7', book: book),
      ];
      notifier.markMissingFile('nope');
      expect(container.read(downloadProvider), hasLength(1));
      expect(container.read(downloadProvider).single.status,
          DownloadStatus.pending);
    });

    test('removeTask deletes the file, clears storage, drops the row',
        () async {
      await notifier.ready;
      final file = File('${tempDir.path}/book.epub')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      storage.history['7'] = <String, dynamic>{
        'title': 'Test Book',
        'filePath': file.path,
      };
      notifier.state = <DownloadTask>[
        DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.completed,
          filePath: file.path,
        ),
      ];
      await notifier.removeTask('7');
      expect(await file.exists(), isFalse);
      expect(storage.removedIds, <String>['7']);
      expect(container.read(downloadProvider), isEmpty);
    });

    test('removeTask on an unknown id is a no-op (idempotent delete)',
        () async {
      await notifier.ready;
      notifier.state = <DownloadTask>[
        const DownloadTask(id: '7', book: book),
      ];
      await notifier.removeTask('nope');
      expect(container.read(downloadProvider), hasLength(1));
      expect(storage.removedIds, isEmpty);
    });

    test('removeTask with a content URI still drops the row', () async {
      await notifier.ready;
      const uri = 'content://media/external/downloads/99';
      notifier.state = <DownloadTask>[
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.completed,
          filePath: uri,
        ),
      ];
      await notifier.removeTask('7');
      expect(storage.removedIds, <String>['7']);
      expect(container.read(downloadProvider), isEmpty);
    });

    test('cancelDownload without a live token is a no-op', () async {
      await notifier.ready;
      notifier.state = <DownloadTask>[
        const DownloadTask(
          id: '7',
          book: book,
          status: DownloadStatus.downloading,
          progress: 0.5,
        ),
      ];
      // No download was started, so no CancelToken exists for '7':
      // cancelDownload returns early instead of flipping the status.
      notifier.cancelDownload('7');
      final task = container.read(downloadProvider).single;
      expect(task.status, DownloadStatus.downloading);
      expect(task.progress, 0.5);
    });
  });
}
