import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Personal profile page booklist API tests (issue #11 fix: the
/// profile document's booklists tab server-renders at most 10 lists;
/// `getUserProfileBooklists` now also reports the paginator's page
/// total, and `getUserProfileBooklistsPage` fetches the paginated
/// route `/profile/{id}/{hash}/booklists?page=N` documents of the
/// same shape — live-verified 2026-11-21).
///
/// Served by a routing stub adapter (no network): each request
/// "path-with-query" maps to its canned page, and every requested URL
/// is captured so the tests can pin the exact route the plugin must
/// hit. Keys are host-relative (the plugin's default mirror is not
/// pinned here — URL assertions build on the plugin's own URL
/// helpers).
class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, String> routes;

  _RoutingAdapter(this.routes);

  final captured = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    captured.add(uri.toString());
    final key = '${uri.path}${uri.query.isEmpty ? '' : '?${uri.query}'}';
    final body = routes[key] ?? routes['404']!;
    return ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: ['text/html; charset=utf-8']},
    );
  }
}

const _profilePath = '/profile/1790607/f094e9';
const _page2Path = '$_profilePath/booklists?page=2';

String _profileDoc({required int lists, int? pagesTotal}) {
  final rows = List.generate(
    lists,
    (i) => '<z-booklist id="${900000 + i}"'
        ' href="/booklist/${900000 + i}/h/list-$i.html"'
        ' topic="第${i + 1}个书单" author="someone"'
        ' authorProfile="$_profilePath" authorAvatar=""'
        ' quantity="3" views="1" comments="0" description=""'
        ' color="0"></z-booklist>',
  ).join('\n');
  final pag = pagesTotal == null
      ? ''
      : '<div class="paginator paginator_booklists">'
          '<a href="$_profilePath/booklists?page=2">2</a>'
          '<a href="$_profilePath/booklists?page=$pagesTotal">Last</a>'
          '</div>';
  return '<html><body>'
      '<div z-tab="comments"></div>'
      '<div z-tab="booklists">'
      '<div class="booklists-list">$rows</div>$pag'
      '</div>'
      '</body></html>';
}

const _challengeHtml =
    '<html><head><title>Just a moment...</title></head>'
    '<body>Checking your browser before accessing.</body></html>';

void main() {
  group('getUserProfileBooklists', () {
    test('returns the tab lists plus the paginator page total', () async {
      final adapter = _RoutingAdapter({
        _profilePath: _profileDoc(lists: 10, pagesTotal: 71),
      });
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklists(
        userId: '1790607',
        userHash: 'f094e9',
      );

      expect(response.success, isTrue);
      expect(response.data!.lists, hasLength(10));
      expect(response.data!.lists.first.id, '900000');
      expect(response.data!.pagesTotal, 71);
      // 写键：缓存读键用 userProfilePageUrl —— 写键必须逐字符等于它。
      expect(
        adapter.captured.single,
        api.userProfilePageUrl(userId: '1790607', userHash: 'f094e9'),
      );
    });

    test('a profile with ≤ 10 lists has no paginator: one page', () async {
      final adapter = _RoutingAdapter({
        _profilePath: _profileDoc(lists: 5),
      });
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklists(
        userId: '1790607',
        userHash: 'f094e9',
      );

      expect(response.success, isTrue);
      expect(response.data!.lists, hasLength(5));
      expect(response.data!.pagesTotal, 1);
    });

    test('the wall still reports the browser-check error', () async {
      final adapter = _RoutingAdapter({_profilePath: _challengeHtml});
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklists(
        userId: '1790607',
        userHash: 'f094e9',
      );

      expect(response.success, isFalse);
      expect(response.error, contains('browser check page'));
    });
  });

  group('getUserProfileBooklistsPage', () {
    test('fetches the paginated route for page ≥ 2', () async {
      final adapter = _RoutingAdapter({
        _page2Path: _profileDoc(lists: 10, pagesTotal: 71),
      });
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklistsPage(
        userId: '1790607',
        userHash: 'f094e9',
        page: 2,
      );

      expect(response.success, isTrue);
      expect(response.data, hasLength(10));
      expect(
        adapter.captured.single,
        api.userProfileBooklistsPageUrl(
          userId: '1790607',
          userHash: 'f094e9',
          page: 2,
        ),
      );
    });

    test('page 1 is rejected: the profile document serves it', () async {
      final adapter = _RoutingAdapter({});
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklistsPage(
        userId: '1790607',
        userHash: 'f094e9',
        page: 1,
      );

      expect(response.success, isFalse);
      expect(adapter.captured, isEmpty);
    });

    test('the wall is reported, not parsed as an empty page', () async {
      final adapter = _RoutingAdapter({_page2Path: _challengeHtml});
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

      final response = await api.getUserProfileBooklistsPage(
        userId: '1790607',
        userHash: 'f094e9',
        page: 2,
      );

      expect(response.success, isFalse);
      expect(response.error, contains('browser check page'));
    });

    test('page documents are NOT handed to the HTML cache', () async {
      // The app only re-reads the profile document (page 1) from the
      // cache, so a page-N document would be dead data.
      final adapter = _RoutingAdapter({
        _page2Path: _profileDoc(lists: 1, pagesTotal: 71),
      });
      final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
      final cached = <String>[];
      api.onBooklistHtmlLoaded = (url, html, fetchedAt) => cached.add(url);

      await api.getUserProfileBooklistsPage(
        userId: '1790607',
        userHash: 'f094e9',
        page: 2,
      );

      expect(cached, isEmpty);
    });
  });
}
