// Ported from warreth/OpenlibExtended (AGPL-3.0) — Open Library
// trending discovery feed.
// Original file: lib/services/open_library.dart (OpenLibrary only;
// GoodReads / PenguinRandomHouse / BookDigits were not ported — zlibx
// only needs the Open Library feed).
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
//
// The feed is the public https://openlibrary.org/trending/daily page
// (no login, no key); failures return an empty list and the caller
// hides the section.

// Package imports:
import 'package:dio/dio.dart';
import 'package:html/parser.dart' show parse;

// Project imports:
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/http_client.dart';

class TrendingBookData {
  final String? title;
  final String? thumbnail;
  TrendingBookData({this.title, this.thumbnail});
}

abstract class TrendingBooksImpl {
  String url = '';
  int timeOutDuration = 20;
  final AppLogger _logger = AppLogger();

  /// Async since phase 4: the parse routes through the Rust bridge
  /// when injected (the Dart implementation stays as the fallback).
  /// [OpenLibrary] is the only subclass.
  Future<List<TrendingBookData>> _parser(dynamic data);

  Future<List<TrendingBookData>> trendingBooks() async {
    // M9: a single-use Dio — close it so its HttpClient (and
    // keep-alive pool) does not leak into a long session.
    final dio = createDio();
    try {
      final response = await dio.get(
        url,
        options: Options(
          sendTimeout: Duration(seconds: timeOutDuration),
          receiveTimeout: Duration(seconds: timeOutDuration),
        ),
      );
      return _parser(response.data.toString());
    } on DioException catch (e) {
      _logger.warning(
        'Failed to fetch trending books',
        tag: 'TrendingBooks',
        metadata: {'url': url, 'error': e.message},
      );
      return [];
    } finally {
      dio.close();
    }
  }
}

class OpenLibrary extends TrendingBooksImpl {
  OpenLibrary() {
    super.url = "https://openlibrary.org/trending/daily";
  }

  @override
  Future<List<TrendingBookData>> _parser(data) async {
    // Phase 4: the Rust bridge parses when injected; on any bridge
    // failure the hook un-registers itself and the Dart implementation
    // below takes over.
    if (openLibraryTrendingParseOverride != null) {
      try {
        return await openLibraryTrendingParseOverride!(data.toString());
      } on Object catch (_) {
        openLibraryTrendingParseOverride = null;
      }
    }
    return _dartParseTrending(data.toString());
  }

  /// The original Dart parse body, kept as the fallback when the Rust
  /// bridge is unavailable.
  static List<TrendingBookData> _dartParseTrending(String html) {
    final document = parse(html);
    final bookList = document.querySelectorAll(
      'li[class="searchResultItem sri--w-main"]',
    );
    final List<TrendingBookData> trendingBooks = [];
    for (var element in bookList) {
      if (element.querySelector('h3[class="booktitle"]')?.text != null &&
          element.querySelector('img[itemprop="image" ]')?.attributes['src'] !=
              null) {
        final String? thumbnail = element
            .querySelector('img[itemprop="image" ]')
            ?.attributes['src'];
        final thumb = thumbnail?.toString() ?? '';
        trendingBooks.add(
          TrendingBookData(
            title: element.querySelector('h3[class="booktitle"]')?.text.trim(),
            // Open Library usually serves protocol-relative src values
            // ("//..."), but an absolute https:// src must not be
            // double-prefixed into `https:https://...`.
            thumbnail: thumb.startsWith('http') ? thumb : 'https:$thumb',
          ),
        );
      }
    }
    return trendingBooks;
  }

  @override
  Future<List<TrendingBookData>> trendingBooks() async {
    // M9: a single-use Dio — close it so its HttpClient (and
    // keep-alive pool) does not leak into a long session.
    final dio = createDio();
    try {
      const timeOutDuration = 5;
      Options timeoutOptions() => Options(
        sendTimeout: const Duration(seconds: timeOutDuration),
        receiveTimeout: const Duration(seconds: timeOutDuration),
      );
      // The two trend pages are independent: fetching them in parallel
      // halves the worst-case wait (2×5s serial → 5s).
      final responses = await Future.wait([
        dio.get(url, options: timeoutOptions()),
        dio.get(
          "https://openlibrary.org/trending/daily?page=2",
          options: timeoutOptions(),
        ),
      ]);
      // L2: parse each page on its own, then merge. Concatenating the
      // two HTML documents into one string left the second
      // `<!DOCTYPE html><html>` as content inside the first body —
      // only the html5 parser's error tolerance kept page 2 visible.
      final first = await _parser(responses[0].data.toString());
      final second = await _parser(responses[1].data.toString());
      return [...first, ...second];
    } on DioException catch (e) {
      _logger.warning(
        'Failed to fetch OpenLibrary trending books',
        tag: 'OpenLibrary',
        metadata: {'error': e.message},
      );
      return [];
    } finally {
      dio.close();
    }
  }
}

// ──────────────────────────────────────────────────────────────────
// Phase 4: injectable Rust parse hook. Same contract as the other
// external-source hooks; when null (default) the Dart _parser above
// is used as the fallback.
// ──────────────────────────────────────────────────────────────────
Future<List<TrendingBookData>> Function(String html)?
openLibraryTrendingParseOverride;
