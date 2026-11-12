// Article search domain of [ZLibraryApi]: the 文章 tab of the site's
// search (`/s/{query}?content_type=article`), an HTML route — there
// is no JSON endpoint for it. Split out as a mixin in the same
// library, `on ZLibraryApiBase`, so it can use the base class's
// private HTTP helpers directly, exactly like the full-text mixin.
part of 'zlibrary_api.dart';

/// Article search methods for [ZLibraryApi].
mixin ZLibraryArticles on ZLibraryApiBase {
  /// The longest query the site's form accepts (the `q` input's
  /// `maxlength`, confirmed in the 2026-11-11 capture); longer
  /// queries are capped client-side.
  static const int articleSearchMaxQueryLength = 200;

  /// Search the site's article index (the 文章 tab, `content_type=
  /// article`). The route is the server-rendered
  /// `/s/{query}?content_type=article` page — confirmed by the
  /// 2026-11-11 capture (zh.z-library.sk, mode-tab link
  /// `/s/金融分析?content_type=article`); there is no eapi JSON
  /// endpoint for articles.
  ///
  /// [order] is the sort dropdown (`bestmatch`, `date`, `year`, ...)
  /// passed through as-is; language / extension / year filters are
  /// NOT sent — the capture does not show their exact parameter
  /// names for this route, so they stay out until device-verified.
  /// [page] is 1-based (the site's pager convention).
  ///
  /// A stale or wrong page is guarded exactly like the full-text
  /// search: the results form re-renders the submitted query in its
  /// `q` input, and a mismatch fails the call instead of painting
  /// the wrong list. Login is NOT required for the route itself;
  /// without a session the site answers a reduced page and the echo
  /// check still applies.
  Future<ApiResponse<ArticleSearchPage>> searchArticles({
    required String query,
    String? order,
    int page = 1,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return ApiResponse.fail('article search: empty query');
    }
    final capped = trimmed.length > articleSearchMaxQueryLength
        ? trimmed.substring(0, articleSearchMaxQueryLength)
        : trimmed;
    // `_getWithRedirects`, not `_get`: the `/s/` route may hop (e.g.
    // a slugged/normalized search URL), and a non-redirect-following
    // `_get` would answer the 30x itself and fail the search. Same
    // helper the category pages use; it re-sends the query params on
    // every hop and returns an error _Raw instead of throwing.
    final raw = await _getWithRedirects(
      '/s/${Uri.encodeComponent(capped)}',
      queryParameters: {
        'content_type': 'article',
        if (order != null) 'order': order,
        'page': page,
      },
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'article search failed',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'article search failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    // Wrong-page guard: see [extractArticleSearchQuery]. The q value
    // is entity-decoded by the parser, so it compares directly
    // against the submitted query.
    final echoedQuery = extractArticleSearchQuery(html);
    if (echoedQuery == null || echoedQuery != capped) {
      return ApiResponse.fail('article search answered a different query',
          statusCode: status);
    }
    // Parse on a background isolate: the results page is a large
    // HTML document and the parse is pure work on a string; the
    // result is plain data (sendable), so the main isolate never
    // blocks on it.
    final pageResult = await Isolate.run(
      () => parseArticleSearchPage(html, baseUrl: _base),
    );
    return ApiResponse.ok(pageResult);
  }

  /// The full URL of one article results page — the string the app's
  /// screens use for their solver fallback (the WebView follows it
  /// with the session cookies installed), same role as
  /// `fulltextPageUrl`. Query is capped like the Dio call above.
  String articlePageUrl({
    required String query,
    String? order,
    int page = 1,
  }) {
    final capped = query.trim().length > articleSearchMaxQueryLength
        ? query.trim().substring(0, articleSearchMaxQueryLength)
        : query.trim();
    final parts = <String>[
      'content_type=article',
      if (order != null) 'order=${Uri.encodeComponent(order)}',
      'page=$page',
    ];
    return '$_base/s/${Uri.encodeComponent(capped)}?${parts.join('&')}';
  }
}
