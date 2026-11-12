import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/book_detail_page_repository.dart';

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

const _wall307Body = '<html><body>307 Temporary Redirect</body></html>';
const _challenge513Html = '''
<html><head><title>Verifying your browser | DiamWall</title></head>
<body><iframe src="/.well-known/diamwall/load/html/5s.html"></iframe></body></html>
''';

class _WallAdapter implements HttpClientAdapter {
  _WallAdapter({this.challengeAfterCookieHop = true, this.challengeOnly = false});

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
          'set-cookie': ['__diamwall=0x1020627754; Path=/; Domain=.z-library.sk'],
          'location': [options.uri.toString()],
        },
      );
    }
    return _html(_pageHtml, 200);
  }

  ResponseBody _html(String html, int status) {
    return ResponseBody.fromString(
      html,
      status,
      headers: {Headers.contentTypeHeader: ['text/html']},
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

    test('a 513 challenge answer fails with the browser-check error',
        () async {
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
}
