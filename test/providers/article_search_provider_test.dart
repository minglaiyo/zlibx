import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/article_search_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

/// [ArticleSearchNotifier] tests: success, failure, load-more
/// dedup, and reset. Synthetic data throughout.
///
/// The fake only implements the methods the notifier's production
/// path actually calls — `searchArticles` (the repository's fetch)
/// and `articlePageUrl` (the solver fallback's URL builder); every
/// other call throws, so a production-path regression surfaces as an
/// UnsupportedError instead of silently returning an empty state.
class _FakeZLibraryApi implements ZLibraryApi {
  _FakeZLibraryApi({required this.pages, this.error});

  final Map<int, ArticleSearchPage> pages;

  /// When set, every fetch fails with this error string.
  final String? error;

  int calls = 0;
  String? lastQuery;
  String? lastOrder;
  int? lastPage;

  /// Every (query, page) pair the fake served — prefetch makes the
  /// notifier fetch one page ahead, so call-count assertions read
  /// this instead of the single lastPage.
  final Set<String> fetched = <String>{};

  void _record(String query, int page) {
    calls++;
    lastQuery = query;
    lastPage = page;
    fetched.add('$query#$page');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<ArticleSearchPage>> searchArticles({
    required String query,
    String? order,
    int page = 1,
  }) async {
    lastOrder = order;
    _record(query, page);
    if (error != null) return ApiResponse.fail(error!);
    return ApiResponse.ok(
      pages[page] ??
          const ArticleSearchPage(
            articles: [],
            total: 0,
            totalPages: 1,
          ),
    );
  }

  @override
  String articlePageUrl({
    required String query,
    String? order,
    int page = 1,
  }) =>
      'https://example.com/s/$query?content_type=article&page=$page';
}

Article _article(int id) => Article(id: id, title: 'Synthetic Article $id');

ProviderContainer _container(_FakeZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('search success: articles, total and hasMore from the page', () async {
    final api = _FakeZLibraryApi(pages: {
      1: ArticleSearchPage(
        articles: [_article(1), _article(2)],
        total: 3,
        totalPages: 2,
      ),
    });
    final container = _container(api);
    await container
        .read(articleSearchProvider.notifier)
        .search(const ArticleSearchParams(query: 'synthetic'));

    final state = container.read(articleSearchProvider);
    expect(state.articles.map((a) => a.id), [1, 2]);
    expect(state.total, 3);
    expect(state.currentPage, 1);
    expect(state.totalPages, 2);
    // 2 merged < total 3 → the tab total keeps the list open.
    expect(state.hasMore, isTrue);
    expect(state.hasSearched, isTrue);
    expect(state.isLoading, isFalse);
    expect(state.isLoadingMore, isFalse);
    expect(state.error, isNull);
    // Page 1 + the page-2 prefetch it seeds when more pages may exist.
    expect(api.calls, 2);
    expect(api.lastQuery, 'synthetic');
  });

  test('search failure: error set, loading false, list empty', () async {
    final api = _FakeZLibraryApi(pages: const {}, error: 'synthetic boom');
    final container = _container(api);
    await container
        .read(articleSearchProvider.notifier)
        .search(const ArticleSearchParams(query: 'synthetic'));

    final state = container.read(articleSearchProvider);
    expect(state.articles, isEmpty);
    expect(state.error, 'synthetic boom');
    expect(state.isLoading, isFalse);
    expect(state.hasSearched, isTrue);
  });

  test('loadMore merges pages without duplicate ids', () async {
    final api = _FakeZLibraryApi(pages: {
      1: ArticleSearchPage(
        articles: [_article(1), _article(2)],
        total: 3,
        totalPages: 2,
      ),
      // Page 2 repeats id 2 (the site's pager can overlap) and adds 3.
      2: ArticleSearchPage(
        articles: [_article(2), _article(3)],
        total: 3,
        totalPages: 2,
      ),
    });
    final container = _container(api);
    final notifier = container.read(articleSearchProvider.notifier);
    await notifier.search(const ArticleSearchParams(query: 'synthetic'));
    await notifier.loadMore();

    final state = container.read(articleSearchProvider);
    expect(state.articles.map((a) => a.id), [1, 2, 3]);
    expect(state.currentPage, 2);
    // Merge (3) reached the tab total and the page total: no more.
    expect(state.hasMore, isFalse);
    expect(api.lastPage, 2);
  });

  test('loadMore keeps the list open while the total is not reached',
      () async {
    final api = _FakeZLibraryApi(pages: {
      1: ArticleSearchPage(
        articles: [_article(1)],
        total: 5,
        totalPages: 2,
      ),
      2: ArticleSearchPage(
        articles: [_article(2)],
        total: 5,
        totalPages: 2,
      ),
    });
    final container = _container(api);
    final notifier = container.read(articleSearchProvider.notifier);
    await notifier.search(const ArticleSearchParams(query: 'synthetic'));
    expect(container.read(articleSearchProvider).hasMore, isTrue);
    await notifier.loadMore();
    // Merge (2) is still short of the tab total (5).
    expect(container.read(articleSearchProvider).hasMore, isTrue);
  });

  test('order and page are passed through to the fetch', () async {
    final api = _FakeZLibraryApi(pages: {
      1: ArticleSearchPage(articles: [_article(1)], total: 1, totalPages: 1),
    });
    final container = _container(api);
    await container
        .read(articleSearchProvider.notifier)
        .search(const ArticleSearchParams(query: 'synthetic', order: 'date'));

    expect(api.lastOrder, 'date');
    // One page (total 1) → no prefetch; only page 1 was fetched.
    expect(api.calls, 1);
    expect(api.fetched, {'synthetic#1'});
  });

  test('reset returns the state to its initial value', () async {
    final api = _FakeZLibraryApi(pages: {
      1: ArticleSearchPage(
        articles: [_article(1)],
        total: 1,
        totalPages: 1,
      ),
    });
    final container = _container(api);
    final notifier = container.read(articleSearchProvider.notifier);
    await notifier.search(const ArticleSearchParams(query: 'synthetic'));
    expect(container.read(articleSearchProvider).hasSearched, isTrue);

    notifier.reset();
    final state = container.read(articleSearchProvider);
    expect(state.articles, isEmpty);
    expect(state.total, 0);
    expect(state.currentPage, 1);
    expect(state.totalPages, 1);
    expect(state.hasMore, isTrue);
    expect(state.isLoading, isFalse);
    expect(state.isLoadingMore, isFalse);
    expect(state.hasSearched, isFalse);
    expect(state.error, isNull);
  });
}
