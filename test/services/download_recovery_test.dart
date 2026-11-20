// 断点恢复（2026-11-21 下载中断修复）：进程死亡后盘上残留的
// `.part` / `.meta` / pending 侧车，启动时按文件名反解回 paused 任
// 务挂回下载页——之前这些残片无人认领，下载页没有那本书，用户只能
// 从详情页重新点下载。
//
// 恢复只读暂存目录与 StorageService（自定义下载路径），不碰网络：
// container 覆盖 storageServiceProvider，API provider 保持默认（惰
// 性构造，恢复路径从不读它）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/services/storage_service.dart';

class _FakeStorage extends StorageService {
  String? customPath;

  @override
  Future<Map<String, dynamic>> getDownloadHistory() async => {};

  @override
  Future<String?> getDownloadPath() async => customPath;
}

void main() {
  late Directory tempDir;
  late _FakeStorage storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('download_recovery');
    storage = _FakeStorage()..customPath = tempDir.path;
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('盘上残片恢复为 paused 任务，书名/扩展名/id 从文件名反解', () async {
    // .part 本体（staging 流）与仅剩侧车+meta 的（pending 流）都要认。
    File('${tempDir.path}/白鹿原 - 123.epub.part').writeAsStringSync('x');
    File('${tempDir.path}/万历十五年 - 456.epub.part.pending.json')
        .writeAsStringSync('{}');
    File('${tempDir.path}/万历十五年 - 456.epub.part.meta')
        .writeAsStringSync('etag');
    // 用户自放/不认识的形态：不动。
    File('${tempDir.path}/random.dat').writeAsStringSync('x');

    final container = makeContainer();
    await container.read(downloadProvider.notifier).ready;

    final tasks = container.read(downloadProvider);
    final ids = tasks.map((t) => t.id).toSet();
    expect(ids, containsAll(['123', '456']), reason: '两种残片形态都要认');

    final t123 = tasks.firstWhere((t) => t.id == '123');
    expect(t123.status, DownloadStatus.paused);
    expect(t123.book.title, '白鹿原');
    expect(t123.book.extension, 'epub');

    final t456 = tasks.firstWhere((t) => t.id == '456');
    expect(t456.status, DownloadStatus.paused);
    expect(t456.book.title, '万历十五年');

    expect(ids.contains('random.dat'), isFalse);
  });

  test('恢复每进程一次：invalidate 重跑 build 不再重复恢复', () async {
    File('${tempDir.path}/白鹿原 - 123.epub.part').writeAsStringSync('x');

    final container = makeContainer();
    await container.read(downloadProvider.notifier).ready;
    expect(container.read(downloadProvider), hasLength(1));

    container.invalidate(downloadProvider);
    await container.read(downloadProvider.notifier).ready;
    // invalidate 清空 state 是既有语义（历史会重灌，残片恢复按进程
    // 一次）——这里钉住"不重复恢复"，同一本书不会出现两行。
    expect(
      container
          .read(downloadProvider)
          .where((t) => t.id == '123')
          .length,
      lessThanOrEqualTo(1),
    );
  });

  test('纯函数：残片后缀剥离与文件名反解', () {
    expect(
      stripPartialSuffixes('白鹿原 - 123.epub.part.pending.json'),
      '白鹿原 - 123.epub',
    );
    expect(stripPartialSuffixes('白鹿原 - 123.epub.part.meta'), '白鹿原 - 123.epub');
    expect(stripPartialSuffixes('白鹿原 - 123.epub.part'), '白鹿原 - 123.epub');
    expect(stripPartialSuffixes('random.dat'), isNull);

    expect(parseSafeFileName('白鹿原 - 123.epub'), (123, '白鹿原', 'epub'));
    // 标题含 " - "：贪婪匹配锚定最后一组 ` - 数字.扩展名`。
    expect(
      parseSafeFileName('My Book - Vol 2 - 99.pdf'),
      (99, 'My Book - Vol 2', 'pdf'),
    );
    // id 非数字/非正：不认。
    expect(parseSafeFileName('书 - abc.epub'), isNull);
    expect(parseSafeFileName('书 - 0.epub'), isNull);
  });
}
