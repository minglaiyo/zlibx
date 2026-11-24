import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/constants/search_filters.dart';
import 'package:zlibx/providers/search_notifier.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

// The eapi-search-fails → HTML-search fallback in SearchNotifier.
//
// Why it exists: as of 2026-11-23 `POST /eapi/book/search` answers
// `400 Access denied` on every mirror, so an eapi-only search is no
// search at all. These tests pin the two properties that make the
// fallback correct rather than merely present: the eapi channel stays
// primary (a working eapi must never spend a second request), and a
// superseded (cancelled) eapi request must not start an HTML one.
//
// The WebView branch is deliberately not covered here: the solver
// needs a real WebView, so a wall answer from the HTML route is
// device-verified only (same split as the article/category provider
// tests).

Book _book(int id) => Book(id: id, title: 'Book $id');

/// [ZLibraryApi] fake with a switchable eapi search verdict and a
/// canned HTML page. Records which channels were used.
class _FakeApi implements ZLibraryApi {
  _FakeApi({
    this.eapiBooks,
    this.htmlPage,
    this.htmlError,
  });

  /// Non-null makes the eapi search succeed with these books.
  final List<Book>? eapiBooks;

  /// The error the eapi search answers with when [eapiBooks] is null
  /// (set by hand in the tests that need a specific verdict).
  String? eapiError;

  /// The page the HTML search returns (null: it fails).
  final BookSearchPage? htmlPage;

  /// The error the HTML search answers with when [htmlPage] is null.
  final String? htmlError;

  int eapiCalls = 0;
  int htmlCalls = 0;
  int htmlPageUrlCalls = 0;
  String? lastHtmlQuery;
  int? lastHtmlPage;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

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
    bool? exact,
    CancelToken? cancelToken,
  }) async {
    eapiCalls++;
    final books = eapiBooks;
    if (books != null) {
      return ApiResponse.ok(List.of(books), meta: {'total_pages': 1});
    }
    return ApiResponse.fail(eapiError ?? 'Access denied', statusCode: 400);
  }

  @override
  Future<ApiResponse<BookSearchPage>> searchBooksHtml({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
    CancelToken? cancelToken,
  }) async {
    htmlCalls++;
    lastHtmlQuery = query;
    lastHtmlPage = page;
    if (cancelToken?.isCancelled == true) {
      return ApiResponse.fail('cancelled');
    }
    final result = htmlPage;
    if (result != null) return ApiResponse.ok(result);
    return ApiResponse.fail(htmlError ?? 'book search failed');
  }

  @override
  String searchBooksHtmlPageUrl({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
  }) {
    htmlPageUrlCalls++;
    return 'https://mirror.example/s/${Uri.encodeComponent(query)}?page=$page';
  }
}

ProviderContainer _container(ZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  return container;
}

const _htmlPage = BookSearchPage(
  books: [Book(id: 1, title: 'Html Book One'), Book(id: 2, title: 'Html Book Two')],
  totalPages: 4,
);

void main() {
  group('search HTML fallback', () {
    test('a working eapi search never touches the HTML route', () async {
      final api = _FakeApi(eapiBooks: [_book(1)]);
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: 'synthetic query'),
          );
      expect(api.eapiCalls, 1);
      expect(api.htmlCalls, 0);
      expect(container.read(searchProvider).books.map((b) => b.id), [1]);
      expect(container.read(searchProvider).error, isNull);
    });

    test('an Access-denied eapi search falls through to the HTML page',
        () async {
      final api = _FakeApi(htmlPage: _htmlPage);
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: 'synthetic query'),
          );
      expect(api.eapiCalls, 1);
      expect(api.htmlCalls, 1);
      expect(api.lastHtmlQuery, 'synthetic query');
      expect(api.lastHtmlPage, 1);
      final state = container.read(searchProvider);
      expect(state.error, isNull);
      expect(state.books.map((b) => b.id), [1, 2]);
      // The pager count comes from the page, not from the eapi meta.
      expect(state.totalPages, 4);
      expect(state.totalPagesUnknown, isFalse);
    });

    test('the HTML page keeps the cards it marks unavailable', () async {
      final api = _FakeApi(
        htmlPage: const BookSearchPage(
          books: [Book(id: 3, title: 'Live'), Book(id: 4, title: 'Gone')],
          unavailableReasons: {4: 'copyright'},
          totalPages: 1,
        ),
      );
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: 'synthetic query'),
          );
      expect(
        container.read(searchProvider).unavailableReasons,
        {4: 'copyright'},
      );
    });

    test('a cancelled eapi search starts no HTML request', () async {
      final api = _FakeApi(htmlPage: _htmlPage);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);
      // Two searches back to back: the first is superseded, and its
      // token is cancelled before the fallback could run. The plugin
      // reports a cancel as an error value (it does not throw), so
      // without the guard the cancelled session would still fire an
      // HTML request.
      final first = notifier.search(SearchParams(query: 'one'));
      await notifier.search(SearchParams(query: 'two'));
      await first;
      expect(api.htmlCalls, 1);
      expect(api.lastHtmlQuery, 'two');
    });

    test('an empty query never reaches the HTML route', () async {
      final api = _FakeApi(htmlPage: _htmlPage);
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: ''),
          );
      expect(api.htmlCalls, 0);
      expect(container.read(searchProvider).books, isEmpty);
    });

    test('a failed HTML search surfaces an error, not an empty list',
        () async {
      final api = _FakeApi(htmlError: 'book search answered a different query');
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: 'synthetic query'),
          );
      final state = container.read(searchProvider);
      expect(state.hasSearched, isTrue);
      expect(state.error, isNotNull);
      expect(state.books, isEmpty);
    });

    test('loadMore pages the HTML channel with the site page number',
        () async {
      final api = _FakeApi(
        htmlPage: const BookSearchPage(
          books: [Book(id: 5, title: 'Page Two')],
          totalPages: 3,
        ),
      );
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'synthetic query'));
      await notifier.loadMore();
      expect(api.htmlCalls, 2);
      expect(api.lastHtmlPage, 2);
      expect(container.read(searchProvider).currentPage, 2);
    });

    test('a page without a pager count keeps paging instead of stopping',
        () async {
      final api = _FakeApi(
        htmlPage: const BookSearchPage(books: [Book(id: 6, title: 'No Pager')]),
      );
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'synthetic query'));
      final state = container.read(searchProvider);
      expect(state.totalPagesUnknown, isTrue);
      // The sentinel total keeps loadMore's guard from stopping the
      // list at page 1 of an unknown-length result.
      expect(state.totalPages, greaterThan(1));
      await notifier.loadMore();
      expect(api.htmlCalls, 2);
    });

    test('a field-scoped search filters the HTML page too', () async {
      final api = _FakeApi(
        htmlPage: const BookSearchPage(
          books: [
            Book(id: 7, title: 'Scoped', author: 'Ada'),
            Book(id: 8, title: 'Other', author: 'Bob'),
          ],
          totalPages: 1,
        ),
      );
      final container = _container(api);
      await container.read(searchProvider.notifier).search(
            SearchParams(query: 'Ada', field: SearchField.author),
          );
      expect(container.read(searchProvider).books.map((b) => b.id), [7]);
    });
  });
}
