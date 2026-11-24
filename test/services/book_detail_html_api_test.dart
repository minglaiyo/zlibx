import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/booklist_solver.dart';

// The detail-page channels of the plugin (`getBookInfoFromHtmlPage`,
// `getSimilarBooksFromHtmlPage`) over a fake adapter — no network.
// What they must guarantee for the app's solver fallback:
//  * the SAME wall error shape as every other HTML route
//    (`'HTTP $status: browser check page'`), because
//    `BooklistSolver.isChallengeError` is what decides whether a
//    WebView opens;
//  * a `/book/…` href is required before any request goes out;
//  * a page that is not a book page fails instead of returning an
//    empty Book (the detail cache would pin it for 7 days);
//  * an empty recommendation shelf is a success, not an error;
//  * `Accept: text/html` — the wall answers JSON-shaped denials to
//    anything else.
//
// Fixtures are synthetic, in the shape site-verified on
// `/book/Ej8q7Dmrv9/三体.html` (2026-11-24); the parsing contract
// itself lives in test/parsers/book_detail_page_test.dart.

const _bookId = '26610712';
const _shortHash = 'Ej8q7Dmrv9';
const _pageHref = '/book/$_shortHash/三体.html';

String _detailPage({
  bool withShelf = true,
  bool withDlButton = true,
  bool withBookId = true,
}) {
  final shelf = withShelf
      ? '<div class="books-mosaic"><z-masonry source="recommend">'
            '<a href="/book/0vpJZoQLRr/ten.html?dsource=recommend">'
            '<z-cover id="102668369" author="杀虫队队员" title="十日终焉">'
            '<img src="https://cdn.example/covers200/a.jpg"></z-cover></a>'
            '</z-masonry></div>'
      : '';
  return '''
<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@type":"Book","name":"三体",
 "author":[{"@type":"Person","name":"刘慈欣"}],
 "publisher":{"@type":"Organization","name":"重庆出版社"},
 "image":"https://cdn.example/covers300/a.jpg","isbn":"9787229042066",
 "numberOfPages":0,"datePublished":2008,
 "inLanguage":{"@type":"Language","name":"chinese"}}
</script></head><body>
<h1 class="book-title">三体</h1><i class="authors">刘慈欣</i>
<div id="bookDescriptionBox">正文段落</div>
<div class="bookDetailsBox">
  <div class='bookProperty property_year'><div class='property_label'>出版年:</div><div class='property_value'>2008</div></div>
  <div class='bookProperty property_file'><div class='property_label'>文件:</div><div class='property_value'>EPUB, 2.48 MB</div></div>
  <div class='bookProperty property_isbn 13'><div class='property_label'>ISBN 13:</div><div class='property_value'>9787229042066</div></div>
</div>
${withDlButton ? '<a class="dlButton addDownloadedBook" href="/dl/ABVGVr08wz" data-book_id="$_bookId">下载</a>' : ''}
${withBookId ? '<span data-book_id="$_bookId"></span>' : ''}
$shelf</body></html>''';
}

const _wallHtml =
    '<html><body>Checking your browser before accessing the site</body></html>';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter();

  String? body;
  int status = 200;

  /// Every request answers the browser-check page.
  bool challenge = false;

  final List<String> requestedUris = [];
  final List<Map<String, dynamic>> requestedHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUris.add(options.uri.toString());
    requestedHeaders.add(options.headers);
    if (challenge) {
      return _html(_wallHtml, statusCode: 513);
    }
    if (options.uri.path.startsWith('/book/')) {
      return _html(body ?? _detailPage(), statusCode: status);
    }
    return ResponseBody.fromString(
      '',
      404,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }

  ResponseBody _html(String body, {int statusCode = 200}) => ResponseBody
      .fromString(
        body,
        statusCode,
        headers: {Headers.contentTypeHeader: ['text/html']},
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeAdapter adapter;
  late ZLibraryApi api;

  setUp(() {
    adapter = _FakeAdapter();
    api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
  });

  group('getBookInfoFromHtmlPage', () {
    test('parses the served page into a book', () async {
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(res.success, isTrue);
      final book = res.data!;
      expect(book.id, 26610712);
      expect(book.title, '三体');
      expect(book.author, '刘慈欣');
      expect(book.year, 2008);
      expect(book.extension, 'epub');
      expect(book.filesizeString, '2.48 MB');
      expect(book.isbn13, '9787229042066');
      // The page's own href and short hash come back on the book, so
      // the detail screen can re-open it and the extras loader can
      // find its page.
      expect(book.href, _pageHref);
      expect(book.hash, _shortHash);
    });

    test('the /dl/ address is resolved against the API host', () async {
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(
        res.data!.downloadPath,
        'https://${api.domain}/dl/ABVGVr08wz',
      );
    });

    test('requests the page as HTML', () async {
      await api.getBookInfoFromHtmlPage(_pageHref);
      expect(adapter.requestedUris, hasLength(1));
      expect(adapter.requestedUris.single, contains('/book/$_shortHash/'));
      expect(adapter.requestedHeaders.single['Accept'], 'text/html');
    });

    test('an absolute href is reduced to its path', () async {
      // eapi/list responses carry the absolute form (device-verified
      // 2026-11-19); the Dio base already supplies the host.
      await api.getBookInfoFromHtmlPage('https://other.example$_pageHref');
      expect(adapter.requestedUris.single, isNot(contains('other.example')));
      expect(adapter.requestedUris.single, contains('/book/'));
    });

    test('a non-book href fails without a request', () async {
      final res = await api.getBookInfoFromHtmlPage('/list/abc');
      expect(res.success, isFalse);
      expect(res.error, contains('bad href'));
      expect(adapter.requestedUris, isEmpty);
    });

    test('a 513 wall answers the browser-check error the solver keys on',
        () async {
      adapter.challenge = true;
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(res.success, isFalse);
      expect(res.error, contains('browser check page'));
      expect(res.statusCode, 513);
      expect(BooklistSolver.isChallengeError(res.error), isTrue);
    });

    test('a 200 wall body answers the same', () async {
      adapter.body = _wallHtml;
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(res.success, isFalse);
      expect(res.error, contains('browser check page'));
    });

    test('a page with no book on it is a failure, not an empty book',
        () async {
      adapter.body = _detailPage(withBookId: false, withDlButton: false);
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(res.success, isFalse);
      expect(res.error, contains('not a book page'));
      expect(res.data, isNull);
    });

    test('a non-2xx page fails with its status', () async {
      adapter.status = 500;
      adapter.body = '<html><body>oops</body></html>';
      final res = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(res.success, isFalse);
    });
  });

  group('getSimilarBooksFromHtmlPage', () {
    test('parses the recommendation shelf', () async {
      final res = await api.getSimilarBooksFromHtmlPage(_pageHref);
      expect(res.success, isTrue);
      final books = res.data!;
      expect(books, hasLength(1));
      expect(books.single.id, 102668369);
      expect(books.single.title, '十日终焉');
      expect(books.single.hash, '0vpJZoQLRr');
      expect(books.single.href, '/book/0vpJZoQLRr/ten.html');
    });

    test('a book with no shelf succeeds with an empty list', () async {
      adapter.body = _detailPage(withShelf: false);
      final res = await api.getSimilarBooksFromHtmlPage(_pageHref);
      expect(res.success, isTrue);
      expect(res.data, isEmpty);
    });

    test('the wall verdict is identical to the body channel', () async {
      adapter.challenge = true;
      final similar = await api.getSimilarBooksFromHtmlPage(_pageHref);
      final body = await api.getBookInfoFromHtmlPage(_pageHref);
      expect(similar.error, body.error);
      expect(similar.statusCode, body.statusCode);
    });

    test('a non-book href fails without a request', () async {
      final res = await api.getSimilarBooksFromHtmlPage('/search/x');
      expect(res.success, isFalse);
      expect(adapter.requestedUris, isEmpty);
    });
  });

  test('the extras channel still reads the same document', () async {
    // The three detail-page readers were unified onto one fetch; the
    // pre-existing extras contract must not have moved.
    final res = await api.fetchBookDetailExtras(_pageHref);
    expect(res.success, isTrue);
    expect(res.data!.metadata.isbn13, '9787229042066');
  });
}
