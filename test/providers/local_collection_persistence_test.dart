import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/local_collection_provider.dart';
import 'package:zlibx/services/annas_models.dart';
import 'package:zlibx/services/hive_service.dart';

/// 本地收藏（方案 C2）的持久化与导入去重。普通 test() + 真实 Hive
/// 临时目录——testWidgets 的 FakeAsync 区里 Hive put 落盘 Future 永不
/// 完成（见 settings_privacy_incognito_test 的教训），持久化类测试全
/// 部走这条通道。
Directory? _hiveDir;

DisplayBook _annaBook(String md5, {String title = 'A book'}) => DisplayBook(
  id: md5,
  title: title,
  author: 'Author',
  cover: 'http://cover/$md5',
  tag: 'EPUB',
  source: BookSource.annasArchive,
  original: BookData(
    title: title,
    author: 'Author',
    thumbnail: 'http://cover/$md5',
    link: '/md5/$md5',
    md5: md5,
    info: 'EPUB',
  ),
);

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('local_collection_test');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir!.delete(recursive: true);
  });

  test('add 后 contains，original 能无损重建详情页所需的 BookData', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(localCollectionProvider.notifier)
        .add(_annaBook('abc12345'));

    final state = container.read(localCollectionProvider);
    expect(state.contains(BookSource.annasArchive, 'abc12345'), isTrue);
    final book = state.books.single;
    expect(book.id, 'abc12345');
    expect(book.title, 'A book');
    expect(book.tag, 'EPUB');
    // 详情页 _ExternalBookDetail 强解包 asAnnaBookData，详情 URL 用
    // bookData.link——重建必须带上。
    expect(book.asAnnaBookData, isNotNull);
    expect(book.asAnnaBookData!.link, '/md5/abc12345');
    // 重复 add 同一本书：不产生第二条（先移除再插入置顶语义）。
    await container
        .read(localCollectionProvider.notifier)
        .add(_annaBook('abc12345', title: 'A book'));
    expect(container.read(localCollectionProvider).books.length, 1);
  });

  test('重启后从落盘值恢复（新容器读同一盒子）', () async {
    await HiveService.settingsBox.clear();
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(localCollectionProvider.notifier).add(_annaBook('deadbeef'));

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final restored = fresh.read(localCollectionProvider).books;
    expect(restored, hasLength(1));
    expect(restored.single.id, 'deadbeef');
    expect(restored.single.asAnnaBookData!.link, '/md5/deadbeef');
  });

  test('remove 生效', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(localCollectionProvider.notifier).add(_annaBook('aa11'));
    await container
        .read(localCollectionProvider.notifier)
        .remove(BookSource.annasArchive, 'aa11');
    expect(container.read(localCollectionProvider).books, isEmpty);
  });

  test('importEntries：按 来源+md5 去重，坏条目丢弃', () async {
    await HiveService.settingsBox.clear();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final entries = [
      {
        'source': 'annasArchive',
        'md5': 'newmd5',
        'title': 'New book',
        'link': '/md5/newmd5',
      },
      // 坏条目：空标题。
      {'source': 'annasArchive', 'md5': 'bad1', 'title': ''},
      // 坏条目：未知来源。
      {'source': 'weird', 'md5': 'bad2', 'title': 'X'},
    ];
    final added = await container
        .read(localCollectionProvider.notifier)
        .importEntries(entries);
    expect(added, 1);
    expect(
      container.read(localCollectionProvider).contains(
        BookSource.annasArchive,
        'newmd5',
      ),
      isTrue,
    );
    // 同一批再导一遍：全部去重，0 新增。
    final again = await container
        .read(localCollectionProvider.notifier)
        .importEntries(entries);
    expect(again, 0);
  });
}
