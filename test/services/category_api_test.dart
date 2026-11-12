import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Category browse + in-category search request tests (all data
// synthetic): the category pages are canned HTML served by a fake
// adapter, so no network runs. Covers the query the plugin sends
// (page / order / q / e / yearFrom / yearTo and the repeated
// `languages[]` / `extensions[]` / `selected_content_types[]`
// keys), the 200-char cap, the bare-id redirect, and the
// challenge-page error shape the provider's solver fallback keys
// on.

String _card(int n) {
  return '''
<z-bookcard id="${90000 + n}" isbn="" termshash="aaaa${n.toRadixString(16)}bbbb" href="/book/AbCdEfGh${n.toString().padLeft(2, '0')}/Synthetic-Book-$n.html" download="/dl/FAKE${n.toString().padLeft(3, '0')}" deleted="0" favorite="0" publisher="Synthetic Press" language="english" year="2021" extension="epub" filesize="1.23 MB" rating="4.5" quality="3" user_token="FAKE-TOKEN-12345" contenttypeparam="" class="ready">
  <img data-src="https://example.com/covers100/fake-cover-$n.png">
  <div slot="title">Synthetic Book $n</div>
  <div slot="author">Test Author $n</div>
  <div slot="note"></div>
  <div slot="extend"></div>
</z-bookcard>''';
}

/// A synthetic category page: [cardCount] cards in
/// `#searchResultBox` plus an inline `pagerOptions` definition when
/// [totalPages] is given, and a search form with [formAction] when
/// given.
String _page({required int cardCount, int? totalPages, String? formAction}) {
  final buffer = StringBuffer('<html><body>');
  if (formAction != null) {
    buffer.write(
      '<form id="searchForm" method="get" action="$formAction"></form>',
    );
  }
  if (totalPages != null) {
    buffer.write(
      '<script>var pagerOptions = {pagesTotal: $totalPages, currentPage: 1};</script>',
    );
  }
  buffer.write('<div id="searchResultBox">');
  for (var n = 1; n <= cardCount; n++) {
    buffer.write('<div class="book-item"><div class="counter">$n</div>');
    buffer.write(_card(n));
    buffer.write('</div>');
  }
  buffer.write('</div></body></html>');
  return buffer.toString();
}

const _twoCardHtml = '''
<html><body>
<script>var pagerOptions = {pagesTotal: 10, currentPage: 1};</script>
<div id="searchResultBox">
  <div class="book-item"><div class="counter">1</div>
    <z-bookcard id="90001" isbn="" termshash="aaaa1bbbb" href="/book/AbCdEfGh01/Synthetic-Book-1.html" download="/dl/FAKE001" deleted="0" favorite="1" publisher="Synthetic Press" language="english" year="2021" extension="epub" filesize="1.23 MB" rating="4.5" quality="3" user_token="FAKE-TOKEN-12345" contenttypeparam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-1.png">
      <div slot="title">Synthetic Book 1</div>
      <div slot="author">Test Author 1</div>
      <div slot="note"></div>
      <div slot="extend"></div>
    </z-bookcard>
  </div>
  <div class="book-item"><div class="counter">2</div>
    <z-bookcard id="90002" isbn="" termshash="aaaa2bbbb" href="/book/AbCdEfGh02/Synthetic-Book-2.html" download="/dl/FAKE002" deleted="1" favorite="0" publisher="Synthetic Press" language="english" year="2021" extension="pdf" filesize="2.34 MB" rating="3.5" quality="2" user_token="FAKE-TOKEN-12345" contenttypeparam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-2.png">
      <div slot="title">Synthetic Book 2</div>
      <div slot="author">Test Author 2</div>
      <div slot="note"></div>
      <div slot="extend"></div>
    </z-bookcard>
  </div>
</div>
</body></html>
''';

/// Serves canned category pages. Records every request URI so the
/// tests can assert on the exact query the plugin built.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.resultsHtml = _twoCardHtml});

  final String resultsHtml;

  /// The bare-id browse answers 302 to the slugged URL once.
  bool redirectBrowseOnce = false;

  /// Every category page answers with a browser-check page.
  bool challenge = false;

  final List<String> requestedUris = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requestedUris.add(uri.toString());
    if (challenge) {
      return _html(
        '<html><body>Checking your browser before accessing the site</body></html>',
      );
    }
    if (uri.path == '/category/528' && redirectBrowseOnce) {
      redirectBrowseOnce = false;
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          'location': ['/category/528/Some-Slug/'],
        },
      );
    }
    if (uri.path.startsWith('/category/528')) {
      return _html(resultsHtml);
    }
    return ResponseBody.fromString(
      '',
      404,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }

  ResponseBody _html(String html, {int statusCode = 200}) {
    return ResponseBody.fromString(
      html,
      statusCode,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  return ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
}

Uri _lastUri(_FakeAdapter adapter) =>
    Uri.parse(adapter.requestedUris.last);

void main() {
  group('getCategoryBooks request', () {
    test('sends page and order on the bare-id path', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final response = await api.getCategoryBooks(
        528,
        page: 2,
        order: 'titleA',
      );
      expect(response.success, isTrue);
      final uri = _lastUri(adapter);
      expect(uri.path, '/category/528');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['order'], 'titleA');
      expect(response.data!.books.length, 2);
      expect(response.data!.totalPages, 10);
      expect(response.data!.books.first.isFavorite, isTrue);
      expect(response.data!.books.last.removed, isTrue);
      expect(response.data!.books.last.unavailableReason, 'copyright');
    });

    test('follows the bare-id redirect, re-applying the query', () async {
      final adapter = _FakeAdapter()..redirectBrowseOnce = true;
      final api = _apiWith(adapter);
      final response = await api.getCategoryBooks(
        528,
        page: 2,
        order: 'popular',
      );
      expect(response.success, isTrue);
      expect(adapter.requestedUris.length, 2);
      final uri = _lastUri(adapter);
      expect(uri.path, '/category/528/Some-Slug/');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['order'], 'popular');
    });

    test('challenge page fails with the browser-check error', () async {
      final adapter = _FakeAdapter()..challenge = true;
      final api = _apiWith(adapter);
      final response = await api.getCategoryBooks(528);
      expect(response.success, isFalse);
      expect(response.error, contains('browser check page'));
    });

    test('50-card page parses with its pagerOptions total', () async {
      final adapter = _FakeAdapter(
        resultsHtml: _page(cardCount: 50, totalPages: 10),
      );
      final api = _apiWith(adapter);
      final response = await api.getCategoryBooks(528);
      expect(response.success, isTrue);
      expect(response.data!.books.length, 50);
      expect(response.data!.totalPages, 10);
    });
  });

  group('searchInCategory request', () {
    test('sends q, e, year range, filters, order and page', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final response = await api.searchInCategory(
        categoryId: 528,
        query: 'synthetic query',
        exact: true,
        yearFrom: 2000,
        yearTo: 2020,
        languages: ['chinese', 'english'],
        extensions: ['epub', 'pdf'],
        contentTypes: ['book'],
        order: 'filesize',
        page: 2,
      );
      expect(response.success, isTrue);
      final uri = _lastUri(adapter);
      expect(uri.path, '/category/528/s/');
      expect(uri.queryParameters['q'], 'synthetic query');
      expect(uri.queryParameters['e'], '1');
      expect(uri.queryParameters['yearFrom'], '2000');
      expect(uri.queryParameters['yearTo'], '2020');
      expect(uri.queryParameters['order'], 'filesize');
      expect(uri.queryParameters['page'], '2');
      // Repeated keys with brackets: Dio's default list format
      // appends `[]` to the bare key.
      expect(
        uri.queryParametersAll['languages[]'],
        ['chinese', 'english'],
      );
      expect(uri.queryParametersAll['extensions[]'], ['epub', 'pdf']);
      expect(
        uri.queryParametersAll['selected_content_types[]'],
        ['book'],
      );
      expect(uri.query.contains('languages[][]'), isFalse);
      expect(uri.query.contains('extensions[][]'), isFalse);
    });

    test('uses the slug from the tree href when given', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      await api.searchInCategory(
        categoryId: 528,
        slug: 'Some-Slug',
        query: 'synthetic query',
      );
      expect(_lastUri(adapter).path, '/category/528/Some-Slug/s/');
    });

    test('caps the query at 200 characters', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final longQuery = 'x' * 250;
      await api.searchInCategory(categoryId: 528, query: longQuery);
      expect(_lastUri(adapter).queryParameters['q'], 'x' * 200);
    });

    test('empty query fails without a request', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final response = await api.searchInCategory(
        categoryId: 528,
        query: '   ',
      );
      expect(response.success, isFalse);
      expect(response.error, 'empty query');
      expect(adapter.requestedUris, isEmpty);
    });
  });

  group('search slug from the page', () {
    test('reads the slug from the search form action', () {
      final page = parseCategoryBooksPage(
        _page(
          cardCount: 1,
          formAction:
              '/category/528/Psychology-Theory-History--Research/s/',
        ),
      );
      expect(page.searchSlug, 'Psychology-Theory-History--Research');
    });

    test('decodes a percent-encoded slug so it is encoded once', () {
      final page = parseCategoryBooksPage(
        _page(cardCount: 1, formAction: '/category/528/Some%20Slug/s/'),
      );
      expect(page.searchSlug, 'Some Slug');
    });

    test('null when the page has no search form', () {
      expect(parseCategoryBooksPage(_page(cardCount: 1)).searchSlug, isNull);
    });
  });

  group('category page URLs', () {
    test('categoryPageUrl is absolute and carries page + order', () {
      final api = _apiWith(_FakeAdapter());
      final url = api.categoryPageUrl(528, page: 2, order: 'popular');
      expect(url, contains('/category/528'));
      expect(Uri.parse(url).queryParameters['page'], '2');
      expect(Uri.parse(url).queryParameters['order'], 'popular');
    });

    test('categorySearchUrl encodes lists as repeated bracket keys', () {
      final api = _apiWith(_FakeAdapter());
      final url = api.categorySearchUrl(
        categoryId: 528,
        query: 'synthetic query',
        languages: ['chinese', 'english'],
      );
      expect(url, contains('/category/528/s/'));
      expect(
        url,
        contains('languages[]=chinese&languages[]=english'),
      );
      expect(url, contains('q=synthetic%20query'));
    });
  });
}
