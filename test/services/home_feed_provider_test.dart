import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/home_feed_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

Book _book(int id) => Book(id: id, title: 'Book $id', author: 'Author');

/// Serves a fixed recommendation list plus numbered popular pages.
class _FakeApi extends ZLibraryApi {
  _FakeApi({
    this.recommended = const <Book>[],
    this.pages = const <int, List<Book>>{},
    this.orderPages = const <String, List<Book>>{},
    this.totalPages = 5,
    this.failRecommended = false,
  }) : super(domain: 'example.com');

  final List<Book> recommended;
  final Map<int, List<Book>> pages;
  final Map<String, List<Book>> orderPages;
  final int totalPages;
  final bool failRecommended;

  final List<String> requestedOrders = <String>[];

  @override
  Future<ApiResponse<List<Book>>> getUserRecommended() async {
    if (failRecommended) {
      return ApiResponse<List<Book>>.fail('cf_blocked');
    }
    return ApiResponse<List<Book>>.ok(recommended);
  }

  @override
  Future<ApiResponse<List<Book>>> search({
    String? message,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int? page,
    int? limit,
  }) async {
    requestedOrders.add(order ?? '');
    final books =
        orderPages['${order ?? ''}:${page ?? 1}'] ??
        pages[page ?? 1] ??
        const <Book>[];
    return ApiResponse<List<Book>>.ok(
      books,
      meta: <String, dynamic>{'total_pages': totalPages},
    );
  }
}

/// Lets the initial bootstrap and its background top-up finish.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

ProviderContainer _container(_FakeApi api) {
  final container = ProviderContainer(
    overrides: <Override>[zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('first load is topped up with the first popular page', () async {
    final api = _FakeApi(
      recommended: <Book>[for (var i = 1; i <= 20; i++) _book(i)],
      pages: <int, List<Book>>{
        1: <Book>[for (var i = 21; i <= 44; i++) _book(i)],
        2: <Book>[for (var i = 45; i <= 68; i++) _book(i)],
        3: <Book>[for (var i = 69; i <= 92; i++) _book(i)],
      },
    );
    final container = _container(api);
    container.read(homeFeedProvider);
    await _settle();
    await pumpEventQueue();

    final state = container.read(homeFeedProvider);
    expect(state.isLoading, isFalse);
    expect(state.books.length, 44);
    expect(state.page, 2);
    expect(state.hasMore, isTrue);
  });

  test('loadMore appends the next page without duplicates', () async {
    final api = _FakeApi(
      recommended: <Book>[for (var i = 1; i <= 20; i++) _book(i)],
      pages: <int, List<Book>>{
        // Page 1 overlaps the last 4 recommendations on purpose.
        1: <Book>[for (var i = 17; i <= 40; i++) _book(i)],
        2: <Book>[for (var i = 41; i <= 64; i++) _book(i)],
      },
    );
    final container = _container(api);
    container.read(homeFeedProvider);
    await _settle();
    await pumpEventQueue();

    expect(container.read(homeFeedProvider).books.length, 40);

    await container.read(homeFeedProvider.notifier).loadMore();
    final state = container.read(homeFeedProvider);
    expect(state.books.length, 64);
    expect(state.books.map((b) => b.id).toSet().length, 64);
  });

  test(
    'refresh prepends the next page so pull-to-refresh shows new books',
    () async {
      final api = _FakeApi(
        recommended: <Book>[for (var i = 1; i <= 20; i++) _book(i)],
        pages: <int, List<Book>>{
          1: <Book>[for (var i = 21; i <= 44; i++) _book(i)],
          2: <Book>[for (var i = 45; i <= 68; i++) _book(i)],
          3: <Book>[for (var i = 69; i <= 92; i++) _book(i)],
        },
      );
      final container = _container(api);
      container.read(homeFeedProvider);
      await _settle();
      await pumpEventQueue();

      final added = await container.read(homeFeedProvider.notifier).refresh();
      expect(added, 24);
      final state = container.read(homeFeedProvider);
      expect(state.books.length, 68);
      expect(state.books.first.id, '45');
    },
  );

  test('an exhausted ordering rolls into the next one', () async {
    final api = _FakeApi(
      recommended: <Book>[_book(1)],
      orderPages: <String, List<Book>>{
        'popular:1': <Book>[_book(2)],
        'date:1': <Book>[_book(3)],
      },
      totalPages: 1,
    );
    final container = _container(api);
    container.read(homeFeedProvider);
    await _settle();
    await pumpEventQueue();

    // The popular ordering had a single page, so the background top-up has
    // already moved on to the "date" ordering.
    expect(container.read(homeFeedProvider).orderIndex, 1);
    await container.read(homeFeedProvider.notifier).loadMore();
    final state = container.read(homeFeedProvider);
    expect(api.requestedOrders.contains('date'), isTrue);
    expect(state.books.map((b) => b.id), contains('3'));
    expect(state.hasMore, isTrue);
  });

  test('a failed bootstrap exposes an error and can be retried', () async {
    final api = _FakeApi(failRecommended: true);
    final container = _container(api);
    container.read(homeFeedProvider);
    await _settle();
    await pumpEventQueue();

    expect(container.read(homeFeedProvider).error, isNotNull);
    expect(container.read(homeFeedProvider).books, isEmpty);
  });
}
