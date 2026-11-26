import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/providers/download_task.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// 孤儿行重链（2026-11-26）：用户清数据后，下载的 MediaStore 行失
/// 归属（owner_package_name NULL），存的 content:// URI 打不开，
/// 但文件还在盘上。历史加载必须按真实路径重链回来，而不是把记录
/// 标成“本地文件已不存在”。
void main() {
  late Directory hiveDir;
  late StorageService storage;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('orphan_relink_hive');
    Hive.init(hiveDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
    storage = StorageService();
    addTearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });
  });

  setUp(() async {
    // 每个用例自己播种；先清掉上一个用例的条目。
    final box = HiveService.libraryBox;
    for (final key in box.keys.toList()) {
      if (key is String && (key.startsWith('dl:') || key == 'dl_order')) {
        await box.delete(key);
      }
    }
  });

  const deadUri = 'content://media/external/downloads/1000016137';

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<DownloadTask> loadTask(ProviderContainer c, String id) async {
    c.read(downloadProvider);
    await c.read(downloadProvider.notifier).ready;
    return c.read(downloadProvider).firstWhere((t) => t.id == id);
  }

  group('orphanRelinkCandidates', () {
    test('顺序：存的真实路径 → 子文件夹重建 → 平铺重建', () {
      expect(
        orphanRelinkCandidates(
          storedRealPath: '/storage/emulated/0/Download/zlibx/stored.pdf',
          externalRoot: '/storage/emulated/0',
          displayName: 'Bird - 1114478.pdf',
          effectiveSubfolder: 'David Burnie',
        ),
        [
          '/storage/emulated/0/Download/zlibx/stored.pdf',
          '/storage/emulated/0/Download/zlibx/David Burnie/Bird - 1114478.pdf',
          '/storage/emulated/0/Download/zlibx/Bird - 1114478.pdf',
        ],
      );
    });

    test('无存路径、无子文件夹：只剩平铺', () {
      expect(
        orphanRelinkCandidates(
          externalRoot: '/storage/emulated/0',
          displayName: 'Bird - 1114478.pdf',
        ),
        ['/storage/emulated/0/Download/zlibx/Bird - 1114478.pdf'],
      );
    });

    test('externalRoot 为空：只剩存的真实路径；空串都跳过', () {
      expect(
        orphanRelinkCandidates(
          storedRealPath: '',
          displayName: 'Bird - 1114478.pdf',
          effectiveSubfolder: '  ',
        ),
        isEmpty,
      );
      expect(
        orphanRelinkCandidates(
          storedRealPath: '/storage/emulated/0/Download/zlibx/stored.pdf',
          displayName: 'Bird - 1114478.pdf',
        ),
        ['/storage/emulated/0/Download/zlibx/stored.pdf'],
      );
    });

    test('重建命中：子文件夹里的文件优先于平铺', () async {
      final root =
          await Directory.systemTemp.createTemp('orphan_relink_candidates');
      addTearDown(() => root.delete(recursive: true));
      const displayName = 'Bird (DK Eyewitness Books) - 1114478.pdf';
      final subFile = File(
        '${root.path}/Download/zlibx/David Burnie/$displayName',
      );
      await subFile.create(recursive: true);
      await subFile.writeAsString('fake pdf');

      final candidates = orphanRelinkCandidates(
        externalRoot: root.path,
        displayName: displayName,
        effectiveSubfolder: 'David Burnie',
      );
      String? found;
      for (final candidate in candidates) {
        if (await File(candidate).exists()) {
          found = candidate;
          break;
        }
      }
      expect(found, subFile.path);
    });

    test('重建命中：只有平铺文件时走平铺候选', () async {
      final root =
          await Directory.systemTemp.createTemp('orphan_relink_flat');
      addTearDown(() => root.delete(recursive: true));
      const displayName = 'Bird (DK Eyewitness Books) - 1114478.pdf';
      final flatFile = File('${root.path}/Download/zlibx/$displayName');
      await flatFile.create(recursive: true);
      await flatFile.writeAsString('fake pdf');

      final candidates = orphanRelinkCandidates(
        externalRoot: root.path,
        displayName: displayName,
        effectiveSubfolder: 'David Burnie',
      );
      String? found;
      for (final candidate in candidates) {
        if (await File(candidate).exists()) {
          found = candidate;
          break;
        }
      }
      expect(found, flatFile.path);
    });
  });

  group('history storage realPath', () {
    test('addToDownloadHistory 存 realPath', () async {
      await storage.addToDownloadHistory(
        '1114478',
        'Bird (DK Eyewitness Books)',
        'David Burnie',
        deadUri,
        cover: 'https://cover.example/1114478.jpg',
        extension: 'pdf',
        realPath: '/storage/emulated/0/Download/zlibx/Bird - 1114478.pdf',
      );
      final history = await storage.getDownloadHistory();
      final entry = history['1114478'] as Map<String, dynamic>;
      expect(
        entry['realPath'],
        '/storage/emulated/0/Download/zlibx/Bird - 1114478.pdf',
      );
      expect(entry['filePath'], deadUri);
    });

    test('addToDownloadHistory 不传 realPath 就不存这个键', () async {
      await storage.addToDownloadHistory(
        '1114478',
        'Bird (DK Eyewitness Books)',
        'David Burnie',
        deadUri,
        extension: 'pdf',
      );
      final history = await storage.getDownloadHistory();
      final entry = history['1114478'] as Map<String, dynamic>;
      expect(entry.containsKey('realPath'), isFalse);
    });

    test('updateDownloadHistoryLocation 只改路径，其余字段不动', () async {
      await storage.addToDownloadHistory(
        '1114478',
        'Bird (DK Eyewitness Books)',
        'David Burnie',
        deadUri,
        cover: 'https://cover.example/1114478.jpg',
        extension: 'pdf',
        source: 'zlibrary',
        customSubfolder: 'David Burnie',
      );
      const newPath =
          '/storage/emulated/0/Download/zlibx/Bird - 1114478.pdf';
      await storage.updateDownloadHistoryLocation(
        '1114478',
        newPath,
        realPath: newPath,
      );
      final history = await storage.getDownloadHistory();
      final entry = history['1114478'] as Map<String, dynamic>;
      expect(entry['filePath'], newPath);
      expect(entry['realPath'], newPath);
      expect(entry['title'], 'Bird (DK Eyewitness Books)');
      expect(entry['author'], 'David Burnie');
      expect(entry['cover'], 'https://cover.example/1114478.jpg');
      expect(entry['extension'], 'pdf');
      expect(entry['source'], 'zlibrary');
      expect(entry['customSubfolder'], 'David Burnie');
      expect(entry['downloadTime'], isNotNull);
    });

    test('updateDownloadHistoryLocation 对不存在的条目是空操作', () async {
      await storage.updateDownloadHistoryLocation(
        '9999999',
        '/storage/emulated/0/Download/zlibx/x.pdf',
        realPath: '/storage/emulated/0/Download/zlibx/x.pdf',
      );
      expect(await storage.getDownloadHistory(), isEmpty);
    });
  });

  group('history load relink', () {
    test('死 URI + 存的真实路径指向真文件 → 已完成，filePath 是真实路径',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('orphan_relink_a');
      addTearDown(() => dir.delete(recursive: true));
      final realFile = File('${dir.path}/Bird - 1114478.pdf');
      await realFile.writeAsString('fake pdf');

      await storage.addToDownloadHistory(
        '1114478',
        'Bird (DK Eyewitness Books)',
        'David Burnie',
        deadUri,
        cover: 'https://cover.example/1114478.jpg',
        extension: 'pdf',
        realPath: realFile.path,
      );

      final task = await loadTask(container(), '1114478');
      expect(task.status, DownloadStatus.completed);
      expect(task.filePath, realFile.path);
      expect(task.missingFile, isFalse);
      expect(task.error, isNull);
      expect(task.fileSize, 'fake pdf'.length);

      // 恢复写回了 Hive：下次加载直接读真实路径，不再重链。
      final history = await storage.getDownloadHistory();
      final entry = history['1114478'] as Map<String, dynamic>;
      expect(entry['filePath'], realFile.path);
      expect(entry['realPath'], realFile.path);
    });

    test('死 URI + 哪儿都没文件 → 失败、missingFile，URI 原样保留',
        () async {
      await storage.addToDownloadHistory(
        '1114478',
        'Bird (DK Eyewitness Books)',
        'David Burnie',
        deadUri,
        cover: 'https://cover.example/1114478.jpg',
        extension: 'pdf',
      );

      final task = await loadTask(container(), '1114478');
      expect(task.status, DownloadStatus.error);
      expect(task.missingFile, isTrue);
      expect(task.filePath, deadUri);
      expect(task.error, 'File not found');
    });
  });
}
