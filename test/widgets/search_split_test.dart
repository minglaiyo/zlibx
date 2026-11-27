// P1-4 split tests: RecentSearchesStore and SearchScrollHandler
// (extracted from search_screen.dart). Both are plain Dart classes
// with no widget tree: the store's de-dup/limit rules and the
// handler's fold/load-more decisions are pinned here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/screens/search/recent_searches_store.dart';
import 'package:zlibx/screens/search/search_scroll_handler.dart';

void main() {
  group('RecentSearchesStore.normalize', () {
    test('non-list input loads as empty', () {
      expect(RecentSearchesStore.normalize(null), isEmpty);
      expect(RecentSearchesStore.normalize('nope'), isEmpty);
      expect(RecentSearchesStore.normalize(42), isEmpty);
    });

    test('trims, drops empties and non-strings, de-dups case-insensitively',
        () {
      expect(
        RecentSearchesStore.normalize(['  Foo ', 'foo', 'BAR', '', '  ', 7]),
        ['Foo', 'BAR'],
      );
    });

    test('caps at 12, first occurrence wins', () {
      final saved = List.generate(13, (i) => 'k$i');
      final loaded = RecentSearchesStore.normalize(saved);
      expect(loaded, hasLength(12));
      expect(loaded.first, 'k0');
      expect(loaded.last, 'k11');
    });
  });

  group('RecentSearchesStore list ops', () {
    test('remembered puts the query first and de-dups', () {
      final store = RecentSearchesStore()..searches = ['a', 'b'];
      expect(store.remembered('B'), ['B', 'a']);
      expect(store.remembered('c'), ['c', 'a', 'b']);
    });

    test('without removes only the exact keyword', () {
      final store = RecentSearchesStore()..searches = ['a', 'b'];
      expect(store.without('a'), ['b']);
      expect(store.without('zzz'), ['a', 'b']);
    });
  });

  group('SearchScrollHandler', () {
    FixedScrollMetrics metrics({required double pixels}) =>
        FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          pixels: pixels,
          viewportDimension: 400,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1.0,
        );

    ScrollUpdateNotification notification({
      required double pixels,
      double? scrollDelta,
    }) => ScrollUpdateNotification(
      metrics: metrics(pixels: pixels),
      context: null,
      scrollDelta: scrollDelta,
    );

    test('starts visible; folds after a sustained downward scroll', () {
      final handler = SearchScrollHandler(onLoadMore: () {});
      addTearDown(handler.dispose);
      expect(handler.headerVisible.value, isTrue);
      // A single pixel is noise: below the 12px threshold, no fold.
      handler.onScrollNotification(
        notification(pixels: 100, scrollDelta: 5),
      );
      expect(handler.headerVisible.value, isTrue);
      // Past the threshold in the same direction: folds away.
      handler.onScrollNotification(
        notification(pixels: 120, scrollDelta: 20),
      );
      expect(handler.headerVisible.value, isFalse);
    });

    test('unfolds on a sustained upward scroll; top always shows it', () {
      var loads = 0;
      final handler = SearchScrollHandler(onLoadMore: () => loads++);
      addTearDown(handler.dispose);
      handler.onScrollNotification(
        notification(pixels: 120, scrollDelta: 20),
      );
      expect(handler.headerVisible.value, isFalse);
      handler.onScrollNotification(
        notification(pixels: 100, scrollDelta: -20),
      );
      expect(handler.headerVisible.value, isTrue);
      // Back at the top: always visible.
      handler.onScrollNotification(
        notification(pixels: 120, scrollDelta: 20),
      );
      expect(handler.headerVisible.value, isFalse);
      handler.onScrollNotification(
        notification(pixels: 0, scrollDelta: -5),
      );
      expect(handler.headerVisible.value, isTrue);
      expect(loads, 0);
    });

    test('loads more within 200px of the bottom', () {
      var loads = 0;
      final handler = SearchScrollHandler(onLoadMore: () => loads++);
      addTearDown(handler.dispose);
      handler.onScrollNotification(
        notification(pixels: 850, scrollDelta: 0),
      );
      expect(loads, 1);
      handler.onScrollNotification(
        notification(pixels: 500, scrollDelta: 0),
      );
      expect(loads, 1);
    });

    test('reset brings the header back', () {
      final handler = SearchScrollHandler(onLoadMore: () {});
      addTearDown(handler.dispose);
      handler.onScrollNotification(
        notification(pixels: 120, scrollDelta: 20),
      );
      expect(handler.headerVisible.value, isFalse);
      handler.reset();
      expect(handler.headerVisible.value, isTrue);
    });
  });
}
