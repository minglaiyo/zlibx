import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/home_feed_cache.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('home_feed_cache_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  setUp(() async {
    await HiveService.settingsBox.clear();
  });

  test('round-trips at most 60 Z-Library books plus pagination state', () async {
    final books = <DisplayBook>[
      for (var i = 1; i <= 70; i++)
        Book(id: i, title: 'Book $i', author: 'Author').toDisplay(),
    ];
    final savedAt = DateTime.now();

    await HomeFeedCache.save(
      books: books,
      savedAt: savedAt,
      page: 3,
      orderIndex: 1,
    );

    final cached = HomeFeedCache.read();
    expect(cached, isNotNull);
    expect(cached!.books.length, 60);
    expect(cached.books.first.title, 'Book 1');
    expect(cached.books.last.title, 'Book 60');
    expect(cached.books.first.asZLibBook, isNotNull);
    expect(cached.page, 3);
    expect(cached.orderIndex, 1);
    expect(
      cached.savedAt.millisecondsSinceEpoch,
      savedAt.millisecondsSinceEpoch,
    );
  });

  test('an expired cache is ignored', () async {
    await HomeFeedCache.save(
      books: <DisplayBook>[Book(id: 1, title: 'Old').toDisplay()],
      savedAt: DateTime.now().subtract(const Duration(days: 8)),
      page: 1,
      orderIndex: 0,
    );

    expect(HomeFeedCache.read(), isNull);
  });

  test('clear removes the warm feed', () async {
    await HomeFeedCache.save(
      books: <DisplayBook>[Book(id: 1, title: 'A').toDisplay()],
      savedAt: DateTime.now(),
      page: 1,
      orderIndex: 0,
    );
    expect(HomeFeedCache.read(), isNotNull);

    await HomeFeedCache.clear();
    expect(HomeFeedCache.read(), isNull);
  });
}
