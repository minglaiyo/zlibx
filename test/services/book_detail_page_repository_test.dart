import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/book_detail_page_repository.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';

// Book detail page fetch tests (all data synthetic): the detail page
// is an HTML route behind the DiamWall, so the repository must (a)
// ride the `307 + set-cookie` cookie hop the wall opens every fresh
// client with, and (b) classify the `513` JS-challenge answer as the
// browser-check error the caller escalates to the WebView solver on.
// The fake adapter replays that exact sequence without a network.

const _pageHtml = '''
<html><body>
<div class="bookDetailsBox">
  <div class="bookProperty property_isbn_13">
    <div class="property_label">ISBN 13:</div>
    <div class="property_value">9787544258609</div>
  </div>
</div>
</body></html>
''';

/// A detail page in the shape site-verified 2026-11-24, carrying both
/// the book itself (property rows + visible /dl/ button) and its
/// recommendation shelf.
const _bookPageHtml = '''
<html><body>
<h1 class="book-title">三体</h1><i class="authors">刘慈欣</i>
<div id="bookDescriptionBox">简介段落</div>
<div class="bookDetailsBox">
  <div class='bookProperty property_year'><div class='property_label'>出版年:</div><div class='property_value'>2008</div></div>
  <div class='bookProperty property_file'><div class='property_label'>文件:</div><div class='property_value'>EPUB, 2.48 MB</div></div>
</div>
<a class="dlButton addDownloadedBook" href="/dl/ABVGVr08wz" data-book_id="26610712">下载</a>
<z-masonry source="recommend"><a href="/book/0vpJZoQLRr/ten.html?dsource=recommend">
<z-cover id="102668369" author="某人" title="十日终焉"><img src="/covers200/a.jpg"></z-cover>
</a></z-masonry>
</body></html>
''';

const _wall307Body = '<html><body>307 Temporary Redirect</body></html>';
const _challenge513Html = '''
<html><head><title>Verifying your browser | DiamWall</title></head>
<body><iframe src="/.well-known/diamwall/load/html/5s.html"></iframe></body></html>
''';

class _WallAdapter implements HttpClientAdapter {
  _WallAdapter({
    this.challengeAfterCookieHop = true,
    this.challengeOnly = false,
    this.body,
  });

  /// The page the book route answers; null means the extras fixture.
  final String? body;

  /// True: hop 0 answers 307 + `set-cookie: __diamwall`, hop 1 (with
  /// the cookie) answers the page. False: hop 0 answers the page.
  final bool challengeAfterCookieHop;

  /// True: every request answers the 513 challenge page (the wall
  /// never trusts the client).
  final bool challengeOnly;

  int hops = 0;
  final List<String> requestedUris = [];
  final List<String?> cookieHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hops++;
    requestedUris.add(options.uri.toString());
    cookieHeaders.add(options.headers['Cookie'] as String?);
    if (challengeOnly) {
      return _html(_challenge513Html, 513);
    }
    if (challengeAfterCookieHop && hops == 1) {
      return ResponseBody.fromString(
        _wall307Body,
        307,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          'set-cookie': [
            '__diamwall=0x1020627754; Path=/; Domain=.z-library.sk',
          ],
          'location': [options.uri.toString()],
        },
      );
    }
    return _html(body ?? _pageHtml, 200);
  }

  ResponseBody _html(String html, int status) {
    return ResponseBody.fromString(
      html,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BookDetailPageRepository _repoWith(_WallAdapter adapter) {
  final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
  return BookDetailPageRepository(api);
}

void main() {
  group('BookDetailPageRepository.fetch', () {
    test('rides the wall cookie hop and parses the page', () async {
      final adapter = _WallAdapter();
      final repo = _repoWith(adapter);
      final response = await repo.fetch(
        href: '/book/8vlDJDmPve/Synthetic-Book.html',
      );

      expect(response.success, isTrue);
      expect(adapter.hops, 2); // 307 wall hop, then the page
      expect(adapter.requestedUris.length, 2);
      // The follow-up request carries the cookie the wall set.
      expect(adapter.cookieHeaders[0], isNull);
      expect(adapter.cookieHeaders[1], contains('__diamwall=0x1020627754'));

      final extras = response.data!;
      expect(extras.metadata.isbn13, '9787544258609');
    });

    test('a direct 200 page parses in one hop', () async {
      final adapter = _WallAdapter(challengeAfterCookieHop: false);
      final repo = _repoWith(adapter);
      final response = await repo.fetch(
        href: '/book/8vlDJDmPve/Synthetic-Book.html',
      );
      expect(response.success, isTrue);
      expect(adapter.hops, 1);
    });

    test('a 513 challenge answer fails with the browser-check error', () async {
      final adapter = _WallAdapter(challengeOnly: true);
      final repo = _repoWith(adapter);
      final response = await repo.fetch(
        href: '/book/8vlDJDmPve/Synthetic-Book.html',
      );

      expect(response.success, isFalse);
      expect(response.error, 'HTTP 513: browser check page');
      expect(repo.isChallengeError(response.error), isTrue);
    });

    test('plugin fetchBookDetailMetadata stays null-contract', () async {
      final adapter = _WallAdapter();
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
      final metadata = await api.fetchBookDetailMetadata(
        '/book/8vlDJDmPve/Synthetic-Book.html',
      );
      expect(metadata, isNotNull);
      expect(metadata!.isbn13, '9787544258609');
      expect(metadata.volume, isNull);
    });

    test('a non /book/ href fails without a request', () async {
      final adapter = _WallAdapter();
      final repo = _repoWith(adapter);
      final response = await repo.fetch(href: '/blog/some-post');
      expect(response.success, isFalse);
      expect(adapter.hops, 0);
    });
  });

  // 详情页的附加字段是装饰：它命中墙时只许后台求解，不许把可见
  // 验证页盖在用户正在读的正文上（bookDetailExtrasProvider 传
  // allowVisibleSolver: false）。这里钉住这个开关本身。
  group('BookDetailPageRepository.fetch solver visibility', () {
    late int visibleCalls;

    setUp(() {
      visibleCalls = 0;
      // 无插件环境的测试 VM：把求解器伪装成"支持 + 移动端"，并把
      // 后台那一路关掉，剩下可见那一路就是唯一变量。
      WebviewChallengeSolver.overrideIsSupported = true;
      WebviewChallengeSolver.overrideIsMobile = true;
      WebviewChallengeSolver.headlessEnabled = false;
      WebviewChallengeSolver.visibleSolverFallback = (url) async {
        visibleCalls++;
        return null; // 用户中途退出：可见那一路也没拿到页面。
      };
    });

    tearDown(() {
      WebviewChallengeSolver.overrideIsSupported = null;
      WebviewChallengeSolver.overrideIsMobile = null;
      WebviewChallengeSolver.headlessEnabled = true;
      WebviewChallengeSolver.visibleSolverFallback = null;
    });

    test('by default a wall escalates to the visible solver', () async {
      final repo = _repoWith(_WallAdapter(challengeOnly: true));
      final response = await repo.fetch(
        href: '/book/8vlDJDmPve/Synthetic-Book.html',
      );

      expect(response.success, isFalse);
      expect(visibleCalls, 1);
    });

    test('allowVisibleSolver: false never pops the challenge page', () async {
      final repo = _repoWith(_WallAdapter(challengeOnly: true));
      final response = await repo.fetch(
        href: '/book/8vlDJDmPve/Synthetic-Book.html',
        allowVisibleSolver: false,
        solverTimeout: const Duration(seconds: 1),
      );

      expect(response.success, isFalse);
      expect(response.error, 'HTTP 513: browser check page');
      expect(visibleCalls, 0);
    });
  });

  group('BookDetailPageRepository book/shelf channels', () {
    test('fetchBook rides the same wall hop as the extras', () async {
      final adapter = _WallAdapter(body: _bookPageHtml);
      final repo = _repoWith(adapter);
      final response = await repo.fetchBook(
        href: '/book/Ej8q7Dmrv9/Synthetic-Book.html',
      );
      expect(response.success, isTrue);
      expect(adapter.hops, 2);
      final book = response.data!;
      expect(book.id, 26610712);
      expect(book.title, '三体');
      expect(book.hash, 'Ej8q7Dmrv9');
      expect(book.downloadPath, contains('/dl/ABVGVr08wz'));
    });

    test('fetchSimilarBooks parses the shelf off one hop', () async {
      final adapter = _WallAdapter(
        body: _bookPageHtml,
        challengeAfterCookieHop: false,
      );
      final repo = _repoWith(adapter);
      final response = await repo.fetchSimilarBooks(
        href: '/book/Ej8q7Dmrv9/Synthetic-Book.html',
      );
      expect(response.success, isTrue);
      expect(response.data!.single.id, 102668369);
      expect(response.data!.single.href, '/book/0vpJZoQLRr/ten.html');
    });

    test(
      'an unbroken wall keeps the browser-check error for the caller',
      () async {
        final adapter = _WallAdapter(challengeOnly: true, body: _bookPageHtml);
        final repo = _repoWith(adapter);
        final response = await repo.fetchBook(
          href: '/book/Ej8q7Dmrv9/Synthetic-Book.html',
        );
        expect(response.success, isFalse);
        expect(response.error, 'HTTP 513: browser check page');
        expect(repo.isChallengeError(response.error), isTrue);
      },
    );

    test('parseBook rejects a non-book document', () {
      final repo = _repoWith(_WallAdapter());
      expect(
        repo.parseBook(
          '<html><body>x</body></html>',
          baseUrl: 'https://z-library.sk',
        ),
        isNull,
      );
      expect(
        repo.parseBook('not html at all', baseUrl: 'https://z-library.sk'),
        isNull,
      );
    });

    test('parseSimilarBooks never throws', () {
      final repo = _repoWith(_WallAdapter());
      expect(
        repo.parseSimilarBooks(
          '<html><body>x',
          baseUrl: 'https://z-library.sk',
        ),
        isEmpty,
      );
    });
  });
}
