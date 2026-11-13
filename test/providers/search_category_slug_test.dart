import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/search_notifier.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

// In-category search slug tests: the search only works at the slugged
// URL (`/category/{id}/{slug}/s/`); the bare `/category/{id}/s/`
// answers an empty page (device-proven 2026-11-12). A failed slug
// resolve is therefore a retryable error, never a silent empty
// result. Synthetic data throughout; the fake answers synchronously
// and records every call so the tests can assert on which URL the
// search did (and did not) request.

Book _book(int id) => Book(id: id, title: 'Synthetic Book $id');

CategoryPage _page(List<int> ids, {String? slug, int? totalPages}) =>
    CategoryPage(
      books: [for (final id in ids) CategoryBook(book: _book(id))],
      totalPages: totalPages,
      searchSlug: slug,
    );

/// [SearchNotifier] fake: a canned browse page (the slug source) and
/// a canned search page, plus a log of every category call so the
/// tests can assert on which URL the search did (and did not) hit.
class _FakeCategoryApi implements ZLibraryApi {
  _FakeCategoryApi({this.browsePage, this.browseError, this.searchPage});

  /// Page `getCategoryBooks` answers (the browse page the slug is
  /// read from). Null means the browse returns an empty page with
  /// no search form, so no slug.
  final CategoryPage? browsePage;

  /// Failure `getCategoryBooks` answers instead of a page (a
  /// challenge error drives the solver path; anything else fails
  /// the resolve outright).
  final String? browseError;

  /// Page `searchInCategory` answers.
  final CategoryPage? searchPage;

  int browseCalls = 0;

  /// Slugs `searchInCategory` was called with (null = the bare URL).
  final List<String?> searchSlugs = [];

  /// Slugs `categorySearchUrl` was called with (the solver-fallback
  /// URL builder).
  final List<String?> searchUrlSlugs = [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<CategoryPage>> getCategoryBooks(
    int categoryId, {
    int page = 1,
    String? order,
  }) async {
    browseCalls++;
    if (browseError != null) return ApiResponse.fail(browseError!);
    return ApiResponse.ok(
      browsePage ?? const CategoryPage(books: []),
    );
  }

  @override
  Future<ApiResponse<CategoryPage>> searchInCategory({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
  }) async {
    searchSlugs.add(slug);
    return ApiResponse.ok(
      searchPage ?? const CategoryPage(books: []),
    );
  }

  @override
  String categorySearchUrl({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
  }) {
    searchUrlSlugs.add(slug);
    final slugged = slug == null || slug.isEmpty ? '' : '/$slug';
    return 'https://example.com/category/$categoryId$slugged/s/?q=$query';
  }

  @override
  String categoryPageUrl(int categoryId, {int page = 1, String? order}) =>
      'https://example.com/category/$categoryId?page=$page';
}

/// A signed-in auth state without touching the real notifier's
/// storage/network init: the notifier under test only reads
/// `authProvider.user` (the solver fallback's session), so a fixed
/// state is all it needs.
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
  group('in-category search slug', () {
    test('a resolved slug searches at the slugged URL', () async {
      final api = _FakeCategoryApi(
        browsePage: _page([1], slug: 'synthetic-slug', totalPages: 1),
        searchPage: _page([2, 3], slug: 'synthetic-slug', totalPages: 1),
      );
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'q', categoryId: 1));
      final state = container.read(searchProvider);
      expect(state.error, isNull);
      expect(state.books.map((b) => b.id), [2, 3]);
      // The search ran at the slugged URL, never the bare one.
      expect(api.searchSlugs, ['synthetic-slug']);
      expect(api.searchUrlSlugs, ['synthetic-slug']);
    });

    test('a failed slug resolve is an error, not an empty result',
        () async {
      final api = _FakeCategoryApi(
        browseError: 'synthetic network failure',
      );
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'q', categoryId: 1));
      final state = container.read(searchProvider);
      // An error (retryable), not a silent empty success.
      expect(state.error, isNotNull);
      expect(state.error, contains('category search address'));
      expect(state.books, isEmpty);
      expect(state.hasSearched, isTrue);
      // No request ever went to the bare search URL: the search
      // itself was never called, and its URL was never built.
      expect(api.searchSlugs, isEmpty);
      expect(api.searchUrlSlugs, isEmpty);
    });

    test('a solver failure during slug resolve is the same error',
        () async {
      final api = _FakeCategoryApi(
        browseError: 'HTTP 503: browser check page',
      );
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'q', categoryId: 1));
      final state = container.read(searchProvider);
      // The solver cannot run in a unit test (no WebView), so the
      // resolve fails the same way as a plain browse failure.
      expect(state.error, isNotNull);
      expect(state.error, contains('category search address'));
      expect(state.books, isEmpty);
      expect(api.searchSlugs, isEmpty);
      expect(api.searchUrlSlugs, isEmpty);
    });

    test('a resolved slug with zero results is a valid empty success',
        () async {
      final api = _FakeCategoryApi(
        browsePage: _page([1], slug: 'synthetic-slug', totalPages: 1),
        searchPage: _page([], slug: 'synthetic-slug', totalPages: 1),
      );
      final container = _container(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      final notifier = container.read(searchProvider.notifier);
      await notifier.search(SearchParams(query: 'q', categoryId: 1));
      final state = container.read(searchProvider);
      // A genuine empty result: success, no error — distinct from
      // the slug-failure error above.
      expect(state.error, isNull);
      expect(state.books, isEmpty);
      expect(state.hasSearched, isTrue);
      expect(api.searchSlugs, ['synthetic-slug']);
    });
  });
}
