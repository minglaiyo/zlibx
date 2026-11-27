// P2-6: 下载引擎状态机(真实 DownloadNotifier + 门控假 API)。
//
// 套子照抄 download_orphan_relink_test.dart:临时 Hive 目录(settings
// + library 两个 box)+ ProviderContainer,另把 settings 的
// download_path 指到临时下载目录,让 _resolveSaveDir 不碰
// path_provider。假 API 的 downloadBook 按"门"放行:每轮只在测试
// 完成对应的门后才抛错/成功,所以进行中/重试/取消的时序都能被测
// 到;成功路径(进 _finalize)不在这里测——它要 MediaStore 发布与
// 历史落盘,已由其它测试覆盖完成态的拼装。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// 门控 API:每次 downloadBook 消费一扇门,门里是本轮要抛的错
/// (null = 成功)。没给门时直接成功,避免测试卡住。
class _FakeZLibraryApi implements ZLibraryApi {
  int downloadBookCalls = 0;

  final List<Completer<Object?>> attemptGates = [];

  @override
  Future<void> downloadBook(
    String bookId,
    String hash,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? title,
    PendingDownloadWriter? pendingWriter,
  }) async {
    downloadBookCalls++;
    final gate = attemptGates.isNotEmpty
        ? attemptGates.removeAt(0)
        : (Completer<Object?>()..complete(null));
    final outcome = await gate.future;
    if (outcome != null) throw outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DioException _connectionError() => DioException(
  requestOptions: RequestOptions(path: 'https://example.com'),
  type: DioExceptionType.connectionError,
);

DioException _notFound() => DioException(
  requestOptions: RequestOptions(path: 'https://example.com'),
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: RequestOptions(path: 'https://example.com'),
    statusCode: 404,
  ),
);

void main() {
  late Directory hiveDir;
  late Directory downloadDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('engine_states_hive');
    Hive.init(hiveDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
    downloadDir = await Directory.systemTemp.createTemp('engine_states_dl');
    await HiveService.settingsBox.put('download_path', downloadDir.path);
    addTearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
      await downloadDir.delete(recursive: true);
    });
  });

  setUp(() async {
    // 上一轮失败会留 sidecar;清掉,免得新引擎启动恢复把它当暂停
    // 任务捡回来,污染本用例的 state。
    for (final entity in downloadDir.listSync()) {
      await entity.delete(recursive: true);
    }
  });

  const book = Book(id: 7, title: 'T', hash: 'abc123');

  ProviderContainer container(_FakeZLibraryApi api) {
    final c = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(StorageService()),
        zlibraryApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<DownloadNotifier> readyEngine(ProviderContainer c) async {
    final engine = c.read(downloadProvider.notifier);
    await engine.ready;
    return engine;
  }

  Future<DownloadTask> waitForStatus(
    ProviderContainer c,
    DownloadStatus status,
  ) async {
    for (var i = 0; i < 200; i++) {
      final matches = c.read(downloadProvider).where((t) => t.id == '7');
      if (matches.isNotEmpty && matches.first.status == status) {
        return matches.first;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError(
      'task 7 never reached $status: ${c.read(downloadProvider)}',
    );
  }

  Future<void> waitForCalls(_FakeZLibraryApi api, int count) async {
    for (var i = 0; i < 400; i++) {
      if (api.downloadBookCalls >= count) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError(
      'downloadBook never reached $count calls: ${api.downloadBookCalls}',
    );
  }

  test('不存在的任务取消/暂停/恢复/置顶/删除是无害 no-op', () async {
    final api = _FakeZLibraryApi();
    final c = container(api);
    final engine = await readyEngine(c);

    engine.cancelDownload('ghost');
    engine.pauseDownload('ghost');
    engine.resumeDownload('ghost');
    engine.pinToTop('ghost');
    await engine.removeTask('ghost');

    expect(c.read(downloadProvider), isEmpty);
  });

  test('removeTask 删掉暂停任务的暂存残片，重启不再恢复', () async {
    final api = _FakeZLibraryApi();
    final c = container(api);
    final engine = await readyEngine(c);

    // 暂停任务在盘上留下的四种痕迹（引擎每轮写 sidecar，暂停保留 .part）。
    final base = '${downloadDir.path}/T - 7.epub';
    for (final suffix in <String>[
      '.part',
      '.part.meta',
      '.part.pending.json',
      '.part.download.json',
    ]) {
      await File('$base$suffix').writeAsString('x');
    }
    engine.state = <DownloadTask>[
      const DownloadTask(id: '7', book: book, status: DownloadStatus.paused),
    ];

    await engine.removeTask('7');

    expect(c.read(downloadProvider), isEmpty);
    for (final suffix in <String>[
      '.part',
      '.part.meta',
      '.part.pending.json',
      '.part.download.json',
    ]) {
      expect(await File('$base$suffix').exists(), isFalse, reason: suffix);
    }
  });

  test('进行中取消后任务记为取消态,且不再重试', () async {
    final api = _FakeZLibraryApi();
    final gate = Completer<Object?>();
    api.attemptGates.add(gate);
    final c = container(api);
    final engine = await readyEngine(c);

    final round = engine.startDownload(book);
    await waitForStatus(c, DownloadStatus.downloading);

    engine.cancelDownload('7');
    expect(
      c.read(downloadProvider).single.status,
      DownloadStatus.cancelled,
    );
    // 取消后在途轮次才失败(可重试的断网错):引擎不得再发起第二轮。
    gate.complete(_connectionError());
    await round;

    expect(api.downloadBookCalls, 1);
    expect(
      c.read(downloadProvider).single.status,
      DownloadStatus.cancelled,
    );
  });

  test('断网失败重试一次,第二次失败后记为错误态', () async {
    final api = _FakeZLibraryApi();
    final first = Completer<Object?>();
    final second = Completer<Object?>();
    api.attemptGates.addAll([first, second]);
    final c = container(api);
    final engine = await readyEngine(c);

    final round = engine.startDownload(book);
    await waitForStatus(c, DownloadStatus.downloading);

    first.complete(_connectionError());
    // 2s 退避后第二轮才发起(以调用次数为准,不硬等固定时长)。
    await waitForCalls(api, 2);
    second.complete(_notFound());
    await round;

    expect(api.downloadBookCalls, 2);
    final task = c.read(downloadProvider).single;
    expect(task.status, DownloadStatus.error);
    expect(task.quotaExceeded, isFalse);
  });

  test('配额耗尽不重试,任务记为配额错误态', () async {
    final api = _FakeZLibraryApi();
    final gate = Completer<Object?>();
    api.attemptGates.add(gate);
    final c = container(api);
    final engine = await readyEngine(c);

    final round = engine.startDownload(book);
    await waitForStatus(c, DownloadStatus.downloading);

    gate.complete(const DownloadLimitReachedException());
    await round;

    expect(api.downloadBookCalls, 1);
    final task = c.read(downloadProvider).single;
    expect(task.status, DownloadStatus.error);
    expect(task.quotaExceeded, isTrue);
  });

  test('重复点击只跑一轮,第二轮不重复入队', () async {
    final api = _FakeZLibraryApi();
    final gate = Completer<Object?>();
    api.attemptGates.add(gate);
    final c = container(api);
    final engine = await readyEngine(c);

    final first = engine.startDownload(book);
    await waitForStatus(c, DownloadStatus.downloading);

    await engine.startDownload(book);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(api.downloadBookCalls, 1);
    expect(
      c.read(downloadProvider).where((t) => t.id == '7'),
      hasLength(1),
    );

    gate.complete(_notFound());
    await first;
    expect(c.read(downloadProvider).single.status, DownloadStatus.error);
  });
}
