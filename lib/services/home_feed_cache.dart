import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../models/display_book.dart';
import '../utils/diagnostics.dart';
import 'hive_service.dart';

/// A warm copy of the home feed, shown instantly on the next cold start.
class CachedHomeFeed {
  const CachedHomeFeed({
    required this.books,
    required this.savedAt,
    required this.page,
    required this.orderIndex,
  });

  final List<DisplayBook> books;
  final DateTime savedAt;
  final int page;
  final int orderIndex;
}

/// Hive-backed cache for the recommendation grid.
///
/// Only Z-Library books are cached (the home feed is Z-Library only) and only
/// the first [maxBooks] rows, so the payload stays small. The cache is cleared
/// by [invalidateAccountScopedProviders] on logout/account switch; a missing
/// or unopened box simply disables it (unit tests run without Hive).
class HomeFeedCache {
  static const String _key = 'home_feed_cache_v1';
  static const int maxBooks = 60;
  static const Duration maxAge = Duration(days: 7);

  static Box? get _box {
    try {
      return HiveService.settingsBox;
    } catch (_) {
      // Hive not initialized (tests) or the box was closed.
      return null;
    }
  }

  static CachedHomeFeed? read() {
    final box = _box;
    if (box == null) return null;
    final raw = box.get(_key);
    if (raw is! Map) return null;

    final savedAtMs = raw['savedAt'];
    if (savedAtMs is! int) return null;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
    final age = DateTime.now().difference(savedAt);
    if (age.isNegative || age > maxAge) return null;

    final rawBooks = raw['books'];
    if (rawBooks is! List) return null;

    final books = <DisplayBook>[];
    for (final item in rawBooks) {
      if (item is! Map) continue;
      try {
        final json = <String, dynamic>{
          for (final entry in item.entries) entry.key.toString(): entry.value,
        };
        final book = Book.fromJson(json);
        if (book.id == 0 || book.title.isEmpty) continue;
        final display = book.toDisplay();
        if (display.id.isEmpty) continue;
        books.add(display);
      } catch (error) {
        logIgnored('home_feed_cache_read', error);
      }
    }
    if (books.isEmpty) return null;

    final page = raw['page'];
    final orderIndex = raw['orderIndex'];
    return CachedHomeFeed(
      books: List<DisplayBook>.unmodifiable(books),
      savedAt: savedAt,
      page: page is int ? page : 1,
      orderIndex: orderIndex is int ? orderIndex : 0,
    );
  }

  static Future<void> save({
    required List<DisplayBook> books,
    required DateTime savedAt,
    required int page,
    required int orderIndex,
  }) async {
    final box = _box;
    if (box == null) return;

    final serialized = <Map<String, dynamic>>[];
    for (final display in books.take(maxBooks)) {
      final book = display.asZLibBook;
      if (book != null) serialized.add(book.toJson());
    }
    if (serialized.isEmpty) return;

    try {
      await box.put(_key, <String, Object?>{
        'savedAt': savedAt.millisecondsSinceEpoch,
        'page': page,
        'orderIndex': orderIndex,
        'books': serialized,
      });
    } catch (error) {
      logIgnored('home_feed_cache_write', error);
    }
  }

  static Future<void> clear() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.delete(_key);
    } catch (error) {
      logIgnored('home_feed_cache_clear', error);
    }
  }
}
