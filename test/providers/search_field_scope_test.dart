import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/constants/search_filters.dart';
import 'package:zlibx/providers/search_notifier.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

// Field-scoped eapi search tests: a detail-page author/publisher tap
// carries a [SearchField], and the eapi search — whose `message`
// matches every field — filters the returned books client-side down
// to the ones whose author/publisher actually contains the query.
// Without the scope, the same query returns books by other authors
// and other publishers (the Issue #8 bug).

Book _book(int id, {String? author, String? publisher, String? series}) =>
    Book(
      id: id,
      title: 'Book $id',
      author: author,
      publisher: publisher,
      series: series,
    );

/// [ZLibraryApi] fake: one canned page of books, echoed for every
/// query. Only `search` is real; every other member throws.
class _FakeApi implements ZLibraryApi {
  _FakeApi({required this.books});

  final List<Book> books;

  int calls = 0;

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
    calls++;
    return ApiResponse.ok(List.of(books), meta: {'total_pages': 1});
  }
}

ProviderContainer _container(ZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('field-scoped eapi search', () {
    test('an author-scoped search drops books by other authors', () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Stephen King', publisher: 'Signet'),
        _book(2, author: 'J.K. Rowling', publisher: 'Bloomsbury'),
        _book(3, author: 'Stephen King', publisher: 'Viking'),
        _book(4, author: 'George Orwell', publisher: 'Secker'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(
        SearchParams(query: 'Stephen King', field: SearchField.author),
      );

      expect(
        container.read(searchProvider).books.map((b) => b.id).toList(),
        [1, 3],
      );
      expect(api.calls, 1);
    });

    test('a publisher-scoped search drops other publishers', () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Stephen King', publisher: 'Signet'),
        _book(2, author: 'J.K. Rowling', publisher: 'Bloomsbury'),
        _book(3, author: 'George Orwell', publisher: 'Signet'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(
        SearchParams(query: 'Signet', field: SearchField.publisher),
      );

      expect(
        container.read(searchProvider).books.map((b) => b.id).toList(),
        [1, 3],
      );
    });

    test('a series-scoped search drops books from other series', () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Frank Herbert', series: 'Dune'),
        _book(2, author: 'Frank Herbert', series: 'Destination: Void'),
        _book(3, author: 'Brian Herbert', series: 'Dune'),
        _book(4, author: 'Frank Herbert'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(
        SearchParams(query: 'Dune', field: SearchField.series),
      );

      expect(
        container.read(searchProvider).books.map((b) => b.id).toList(),
        [1, 3],
      );
    });

    test('matching is case-insensitive', () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Stephen King'),
        _book(2, author: 'stephen king'),
        _book(3, author: 'Stephen King Archive'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(
        SearchParams(query: 'STEPHEN KING', field: SearchField.author),
      );

      expect(container.read(searchProvider).books, hasLength(3));
    });

    test('an unscoped search keeps every book (no regression)', () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Stephen King'),
        _book(2, author: 'J.K. Rowling'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(SearchParams(query: 'Stephen King'));

      expect(container.read(searchProvider).books, hasLength(2));
    });

    test('a scoped search with no matching book returns an empty list',
        () async {
      final api = _FakeApi(books: [
        _book(1, author: 'Stephen King'),
        _book(2, author: 'J.K. Rowling'),
      ]);
      final container = _container(api);
      final notifier = container.read(searchProvider.notifier);

      await notifier.search(
        SearchParams(query: 'Ursula K. Le Guin', field: SearchField.author),
      );

      expect(container.read(searchProvider).books, isEmpty);
      expect(container.read(searchProvider).error, isNull);
    });
  });
}
