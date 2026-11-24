import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// The HTML book search (`/s/{query}`), served by a fake adapter from
// canned synthetic HTML — no network runs. Covers the exact request
// the plugin builds (path-encoded query, the site's own filter keys,
// `e=1`, `page`), the wrong-query guard, the browser-check error
// shape the provider's solver fallback keys on, and the fields the
// fallback then depends on (short hash + `/dl/` link).

String _card(int n, {String deleted = '0'}) {
  return '''
<z-bookcard id="${90000 + n}" isbn="" termshash="aaaa${n.toRadixString(16)}bbbb" href="/book/AbCdEfGh${n.toString().padLeft(2, '0')}/Synthetic-Book-$n.html" download="/dl/FAKE${n.toString().padLeft(3, '0')}" deleted="$deleted" publisher="Synthetic Press" language="english" year="2021" extension="epub" filesize="1.23 MB" rating="4.5" quality="3" user_token="FAKE-TOKEN-12345" contentTypeParam="" class="ready">
  <img data-src="https://example.com/covers100/fake-cover-$n.png">
  <div slot="title">Synthetic Book $n</div>
  <div slot="author">Test Author $n</div>
</z-bookcard>''';
}

/// A synthetic results page echoing [echo] in its `q` input, with
/// [cardCount] cards and a `pagerOptions` count when [totalPages] is
/// given.
String _page({
  required int cardCount,
  String echo = 'synthetic query',
  int? totalPages,
  String? deleted,
}) {
  final buffer = StringBuffer('<html><body>');
  buffer.write(
    '<form id="searchForm" method="get" action="/s/">'
    '<input type="text" name="q" value="$echo"></form>',
  );
  if (totalPages != null) {
    buffer.write(
      '<script>var pagerOptions = {pagesTotal: $totalPages, pageCurrent: 1};</script>',
    );
  }
  buffer.write('<div id="searchResultBox">');
  for (var n = 1; n <= cardCount; n++) {
    buffer.write('<div class="book-item"><div class="counter">$n</div>');
    buffer.write(_card(n, deleted: n == 1 && deleted != null ? deleted : '0'));
    buffer.write('</div>');
  }
  buffer.write('</div></body></html>');
  return buffer.toString();
}

const _wallHtml = '''
<html><body>Checking your browser before accessing the site</body></html>
''';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.html, this.status = 200});

  /// Canned body for the `/s/` route; null means a 2-card page.
  final String? html;

  /// Status the `/s/` route answers with.
  final int status;

  /// Every request answers the browser-check page.
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
      return _html(_wallHtml, statusCode: 513);
    }
    if (uri.path.startsWith('/s/')) {
      return _html(html ?? _page(cardCount: 2, totalPages: 7),
          statusCode: status);
    }
    return ResponseBody.fromString(
      '',
      404,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }

  ResponseBody _html(String body, {int statusCode = 200}) =>
      ResponseBody.fromString(
        body,
        statusCode,
        headers: {Headers.contentTypeHeader: ['text/html']},
      );

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) =>
    ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

Uri _lastUri(_FakeAdapter adapter) => Uri.parse(adapter.requestedUris.last);

void main() {
  group('searchBooksHtml request', () {
    test('puts the query in the path and encodes it', () async {
      final adapter = _FakeAdapter(
        html: _page(cardCount: 2, echo: 'synthetic 中文'),
      );
      final api = _apiWith(adapter);
      final response = await api.searchBooksHtml(query: 'synthetic 中文');
      expect(response.success, isTrue);
      final uri = _lastUri(adapter);
      // The path arrives percent-encoded (that is what the site
      // receives); decode it before comparing.
      expect(Uri.decodeFull(uri.path), '/s/synthetic 中文');
      expect(uri.toString(), contains('page=1'));
    });

    test('sends the site form filter keys', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      await api.searchBooksHtml(
        query: 'synthetic query',
        order: 'date',
        page: 3,
        exact: true,
        yearFrom: 1990,
        yearTo: 2005,
        languages: const ['english', '中文'],
        extensions: const ['epub'],
      );
      final uri = _lastUri(adapter);
      expect(uri.queryParameters['order'], 'date');
      expect(uri.queryParameters['page'], '3');
      expect(uri.queryParameters['e'], '1');
      expect(uri.queryParameters['yearFrom'], '1990');
      expect(uri.queryParameters['yearTo'], '2005');
      // multiCompatible list format: the bracketed keys the site's
      // own form submits, never `languages[][]`.
      final pairs = uri.query.split('&');
      expect(pairs.where((p) => p.startsWith('languages%5B%5D=')).length, 2);
      expect(pairs.where((p) => p.startsWith('extensions%5B%5D=')).length, 1);
    });

    test('fails an empty query without a request', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final response = await api.searchBooksHtml(query: '   ');
      expect(response.success, isFalse);
      expect(response.error, 'book search: empty query');
      expect(adapter.requestedUris, isEmpty);
    });

    test('trims the query before putting it in the path', () async {
      final adapter = _FakeAdapter(html: _page(cardCount: 1));
      final api = _apiWith(adapter);
      final response = await api.searchBooksHtml(query: '  synthetic query  ');
      expect(response.success, isTrue);
      expect(Uri.decodeFull(_lastUri(adapter).path), '/s/synthetic query');
    });
  });

  group('searchBooksHtml results', () {
    test('returns the parsed page with the site totals', () async {
      final api = _apiWith(_FakeAdapter());
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isTrue);
      final page = response.data!;
      expect(page.books, hasLength(2));
      expect(page.totalPages, 7);
      expect(page.books.first.hash, 'AbCdEfGh01');
      expect(page.books.first.downloadPath,
          'https://bookroom.lifestyle/dl/FAKE001');
    });

    test('carries the per-card unavailability', () async {
      final api = _apiWith(
        _FakeAdapter(html: _page(cardCount: 2, deleted: '5')),
      );
      final page = (await api.searchBooksHtml(query: 'synthetic query')).data!;
      expect(page.books, hasLength(2));
      expect(page.unavailableReasons, {90001: 'removed'});
    });

    test('rejects a page that echoes a different query', () async {
      final api = _apiWith(
        _FakeAdapter(html: _page(cardCount: 2, echo: 'something else')),
      );
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isFalse);
      expect(response.error, 'book search answered a different query');
    });

    test('accepts a zero-result page as a successful search', () async {
      final api = _apiWith(_FakeAdapter(html: _page(cardCount: 0)));
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isTrue);
      expect(response.data!.books, isEmpty);
    });
  });

  group('searchBooksHtml wall reporting', () {
    test('reports the browser-check page so the solver can take over',
        () async {
      final adapter = _FakeAdapter()..challenge = true;
      final api = _apiWith(adapter);
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isFalse);
      expect(response.error, contains('browser check page'));
      expect(response.statusCode, 513);
    });

    test('reports a 200 challenge body as a wall too', () async {
      final api = _apiWith(_FakeAdapter(html: _wallHtml));
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isFalse);
      expect(response.error, contains('browser check page'));
    });

    test('a non-200 without a wall body keeps its HTTP error', () async {
      final api = _apiWith(
        _FakeAdapter(html: '<html><body>gone</body></html>', status: 500),
      );
      final response = await api.searchBooksHtml(query: 'synthetic query');
      expect(response.success, isFalse);
      expect(response.statusCode, 500);
      expect(response.error, isNot(contains('browser check page')));
    });
  });

  group('searchBooksHtmlPageUrl', () {
    test('builds the same request as a URL the solver can open', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);
      final url = api.searchBooksHtmlPageUrl(
        query: 'synthetic 中文',
        order: 'date',
        page: 2,
        exact: true,
        languages: const ['english'],
        extensions: const ['epub', 'pdf'],
        yearFrom: 1990,
      );
      await api.searchBooksHtml(
        query: 'synthetic 中文',
        order: 'date',
        page: 2,
        exact: true,
        languages: const ['english'],
        extensions: const ['epub', 'pdf'],
        yearFrom: 1990,
      );
      final expected = Uri.parse(url);
      final sent = _lastUri(adapter);
      expect(expected.path, sent.path);
      // Compared as raw pairs: the URL builder emits the site's
      // bracketed keys literally (`languages[]=english`), which is
      // what dio's multiCompatible format produces too.
      List<String> pairs(Uri uri) => uri.query.split('&')
        ..sort();
      expect(pairs(expected), pairs(sent));
    });
  });
}
