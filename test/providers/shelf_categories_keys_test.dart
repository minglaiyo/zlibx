import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/models/unified_shelf_item.dart';
import 'package:zlibx/providers/shelf_categories_provider.dart';
import 'package:zlibx/services/hive_service.dart';

/// 分类 provider 的按键分配入口（方案 C1/C3 新增）：下载页与备份导入
/// 都按 categoryKey 直接落键，不再绕 UnifiedShelfItem。
Directory? _hiveDir;

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('shelf_cat_keys');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveDir!.delete(recursive: true);
  });

  test('assignKeys：按 download:<bookId> 键写入与移除', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(shelfCategoriesProvider.notifier);
    await notifier.create('Fiction');
    final categoryId = container.read(shelfCategoriesProvider).categories.last.id;

    await notifier.assignKeys(['download:42'], categoryId);
    expect(container.read(shelfCategoriesProvider).assignments['download:42'], categoryId);

    // 同一棵分类树：书架条目的 categoryKey（library:<id>）与下载键共存。
    await notifier.assignKeys(['library:7'], categoryId);
    final assignments = container.read(shelfCategoriesProvider).assignments;
    expect(assignments['download:42'], categoryId);
    expect(assignments['library:7'], categoryId);

    await notifier.assignKeys(['download:42'], null);
    expect(
      container.read(shelfCategoriesProvider).assignments.containsKey('download:42'),
      isFalse,
    );
  });

  test('assign 与 assignKeys 等价（categoryKey 委托）', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(shelfCategoriesProvider.notifier);
    await notifier.create('Tech');
    final categoryId = container.read(shelfCategoriesProvider).categories.last.id;

    const item = UnifiedShelfItem(
      source: ShelfSource.local,
      rawBookId: 'md5x',
      displayBook: DisplayBook(
        id: 'md5x',
        title: 'T',
        source: BookSource.libgen,
      ),
    );
    await notifier.assign([item], categoryId);
    expect(container.read(shelfCategoriesProvider).assignments['local:md5x'], categoryId);
  });

  test('assignEntries：先整体校验，坏分类 id 一条都不写', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(shelfCategoriesProvider.notifier);
    await notifier.create('History');
    final categoryId = container.read(shelfCategoriesProvider).categories.last.id;

    await expectLater(
      notifier.assignEntries({'download:1': categoryId, 'download:2': 'nope'}),
      throwsArgumentError,
    );
    // 校验失败时不能落任何一条。
    expect(container.read(shelfCategoriesProvider).assignments, isEmpty);

    await notifier.assignEntries({'download:1': categoryId});
    expect(
      container.read(shelfCategoriesProvider).assignments['download:1'],
      categoryId,
    );
  });
}
