import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/article_search_provider.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/fulltext_search_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

// Next-page prefetch tests for the two search notifiers: the page
// after a successful load is fetched speculatively (one page ahead,
// fast Dio path only) and consumed by loadMore without a second
// fetch. Synthetic data throughout; every fake answers synchronously,
// so by the time the test's continuation runs the prefetch is either
// parked in the notifier or still in flight — both paths end in the
// same observable state and the call counts below hold for either.

const _pageSize = ZLibraryFullText.fulltextPageSize; // 50

FullTextHit _fullTextHit(int id) => FullTextHit(
      book: Book(id: id, title: 'Synthetic Full-Text Book $id'),
      snippet: const [
        FullTextSnippetPart(text: 'synthetic passage', highlighted: true),
      ],
      removed: false,
    );

FullTextSearchPage _fullTextPage(int firstId, int count, {int total = 999}) {
  return FullTextSearchPage(
    hits: [
      for (var i = 0; i < count; i++) _fullTextHit(firstId + i),
    ],
    total: total,
    totalPages: 1,
  );
}

/// [FullTextSearchNotifier] fake: canned pages keyed by page number
/// (the same fixture serves every query; the fetch log distinguishes
/// the searches), an optional challenge wall per page, and a fetch
/// log of `query#page` pairs for the prefetch assertions.
class _FakeFullTextApi implements ZLibraryApi {
  _FakeFullTextApi({required this.pages, this.challengeOn = const {}});

  /// Hits per page; a page missing here fails the fetch (the
  /// prefetch failure path).
  final Map<int, List<int>> pages;
  final Set<int> challengeOn;

  int calls = 0;
  final Set<String> fetched = <String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<FullTextSearchPage>> searchFullText({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
  }) async {
    calls++;
    fetched.add('$query#$page');
    if (challengeOn.contains(page)) {
      return ApiResponse.fail(
        'HTTP 503: browser check page',
        statusCode: 503,
      );
    }
    final ids = pages[page];
    if (ids == null) return ApiResponse.fail('no fixture for page $page');
    return ApiResponse.ok(_fullTextPage(ids.first, ids.length));
  }

  @override
  String? get fulltextToken => null;

  @override
  String fulltextPageUrl({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
    String? token,
  }) =>
      'https://example.com/fulltext/'
      '?q=$query&token=$token&page=$page';
}

Article _article(int id) => Article(id: id, title: 'Synthetic Article $id');

class _FakeArticleApi implements ZLibraryApi {
  _FakeArticleApi({required this.pages});

  final Map<int, List<int>> pages;

  int calls = 0;
  final Set<String> fetched = <String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<ArticleSearchPage>> searchArticles({
    required String query,
    String? order,
    int page = 1,
  }) async {
    calls++;
    fetched.add('$query#$page');
    final ids = pages[page];
    if (ids == null) return ApiResponse.fail('no fixture for page $page');
    return ApiResponse.ok(ArticleSearchPage(
      articles: [for (final id in ids) _article(id)],
      total: 4,
      totalPages: 2,
    ));
  }

  @override
  String articlePageUrl({
    required String query,
    String? order,
    int page = 1,
  }) =>
      'https://example.com/s/$query?content_type=article&page=$page';
}

/// A signed-in auth state without touching the real notifier's
/// storage/network init: the notifiers under test only read
/// `authProvider.user` (the full-text login gate and the solver
/// fallback's session), so a fixed state is all they need.
class _SignedInAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        user: User(
          id: '1',
          email: 'synthetic@example.com',
          name: 'Synthetic User',
          remixUserkey: 'key',
        ),
      );
}

ProviderContainer _container({
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedInAuthNotifier.new),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('full-text search prefetch', () {
    test('a full page seeds a prefetch that loadMore consumes directly',
        () async {
      final api = _FakeFullTextApi(pages: {
        1: [for (var i = 0; i < _pageSize; i++) i],
        2: [for (var i = 0; i < _pageSize; i++) 100 + i],
      });
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(fulltextSearchProvider.notifier);
      await notifier.search(const FullTextSearchParams(query: 'q'));
      // Page 1 + the page-2 prefetch it seeded.
      expect(api.calls, 2);
      expect(container.read(fulltextSearchProvider).currentPage, 1);

      await notifier.loadMore();
      // The prefetch was consumed: page 2 painted without a fetch.
      // Consuming it seeds the page-3 prefetch, which fails (no
      // fixture) — a fetch, but never a state change.
      expect(api.calls, 3);
      expect(api.fetched, {'q#1', 'q#2', 'q#3'});
      final state = container.read(fulltextSearchProvider);
      expect(state.currentPage, 2);
      expect(state.hits, hasLength(_pageSize * 2));
      expect(state.isLoadingMore, isFalse);
      expect(state.error, isNull);
    });

    test('a new search drops the previous search\'s prefetch', () async {
      final api = _FakeFullTextApi(pages: {
        1: [for (var i = 0; i < _pageSize; i++) i],
        2: [for (var i = 0; i < _pageSize; i++) 100 + i],
      });
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(fulltextSearchProvider.notifier);
      await notifier.search(const FullTextSearchParams(query: 'q1'));
      await notifier.search(const FullTextSearchParams(query: 'q2'));
      // q1: page 1 + discarded page-2 prefetch; q2: page 1 + its own
      // page-2 prefetch. The q1 prefetch's RESULT is discarded even
      // though its fetch already ran.
      expect(api.fetched.containsAll({'q1#1', 'q1#2', 'q2#1', 'q2#2'}),
          isTrue);

      await notifier.loadMore();
      // Consumes q2's prefetch — the merged list is q2's page 2 only
      // on top of q2's page 1 (no q1 hits survive). Consuming seeds
      // the q2 page-3 prefetch (no fixture → failed fetch).
      expect(api.calls, 5);
      final state = container.read(fulltextSearchProvider);
      expect(state.currentPage, 2);
      expect(state.hits, hasLength(_pageSize * 2));
    });

    test('a short last page seeds no prefetch', () async {
      final api = _FakeFullTextApi(pages: {
        1: [1, 2, 3], // < 50 hits → hasMore false
      });
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(fulltextSearchProvider.notifier);
      await notifier.search(const FullTextSearchParams(query: 'q'));
      expect(container.read(fulltextSearchProvider).hasMore, isFalse);
      expect(api.calls, 1);
      await notifier.loadMore(); // guarded no-op
      expect(api.calls, 1);
    });

    test('a failed prefetch falls back to a normal loadMore fetch',
        () async {
      final api = _FakeFullTextApi(pages: {
        1: [for (var i = 0; i < _pageSize; i++) i],
        // Page 2 missing → the prefetch fails; loadMore's normal path
        // also fails; the state keeps the error and stops loading.
      });
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(fulltextSearchProvider.notifier);
      await notifier.search(const FullTextSearchParams(query: 'q'));
      expect(api.calls, 2); // page 1 + failed page-2 prefetch

      await notifier.loadMore();
      // The dead prefetch is NOT retried forever: the normal load ran
      // once and its failure is the recorded outcome.
      expect(api.calls, 3);
      final state = container.read(fulltextSearchProvider);
      expect(state.isLoadingMore, isFalse);
      expect(state.currentPage, 1);
      expect(state.error, isNull); // loadMore keeps the list, no error
    });

    test('a walled first page never seeds a prefetch', () async {
      final api = _FakeFullTextApi(pages: {
        1: [for (var i = 0; i < _pageSize; i++) i],
      }, challengeOn: {1});
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(fulltextSearchProvider.notifier);
      await notifier.search(const FullTextSearchParams(query: 'q'));
      // The solver fallback cannot run in a unit test (no WebView);
      // the load fails either way and — the point here — no
      // speculative page-2 fetch is started behind it.
      expect(api.calls, 1);
      expect(api.fetched, {'q#1'});
      expect(container.read(fulltextSearchProvider).error, isNotNull);
    });
  });

  group('article search prefetch', () {
    test('a page with more total seeds a prefetch loadMore consumes',
        () async {
      final api = _FakeArticleApi(pages: {
        1: [1, 2],
        2: [3, 4],
      });
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(articleSearchProvider.notifier);
      await notifier.search(const ArticleSearchParams(query: 'q'));
      // Page 1 + the page-2 prefetch (2 merged < total 4).
      expect(api.calls, 2);
      expect(container.read(articleSearchProvider).currentPage, 1);

      await notifier.loadMore();
      expect(api.calls, 2);
      expect(api.fetched, {'q#1', 'q#2'});
      final state = container.read(articleSearchProvider);
      expect(state.currentPage, 2);
      expect(state.articles.map((a) => a.id), [1, 2, 3, 4]);
      expect(state.hasMore, isFalse);
      expect(state.isLoadingMore, isFalse);
    });
  });
}
