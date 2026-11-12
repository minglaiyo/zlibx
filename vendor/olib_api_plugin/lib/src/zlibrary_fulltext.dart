// Full-text search domain of [ZLibraryApi]: searching inside book
// texts (`/fulltext`), an HTML route — there is no JSON endpoint.
// The token is a per-session value rendered into the search form's
// hidden field; it is fetched from the page and cached in memory
// only, never hardcoded. Split out as a mixin in the same library,
// `on ZLibraryApiBase`, so it can use the base class's private HTTP
// helpers directly.
part of 'zlibrary_api.dart';

/// Full-text search methods for [ZLibraryApi].
mixin ZLibraryFullText on ZLibraryApiBase {
  /// Books the site renders per full-text results page.
  static const int fulltextPageSize = 50;

  /// The longest query the site's form accepts (the `q` input's
  /// `maxlength`); longer queries are capped client-side.
  static const int fulltextMaxQueryLength = 200;

  String? _fulltextToken;

  /// The user the cached token was fetched for. The token is bound
  /// to the login session, so a different user (account switch) or
  /// no user (logout) invalidates it without any explicit clearing.
  String? _fulltextTokenUserId;

  /// When the cached token was FETCHED — never slid forward on use,
  /// so the reuse window in [searchFullText] always counts from the
  /// fetch itself and a token sitting unused past the window is
  /// refetched even though nothing rotated it (the conservative side
  /// of an unknown server TTL).
  DateTime? _fulltextTokenAt;

  /// The cached full-text token for the current session, or null
  /// when no token has been fetched (yet) for the signed-in user.
  /// The solver fallback reads it to build a results URL; it never
  /// triggers a network fetch.
  String? get fulltextToken =>
      _fulltextTokenUserId == _userId ? _fulltextToken : null;

  /// How long a fetched token is trusted for reuse in
  /// [searchFullText]. A getter rather than a constant so tests can
  /// shrink it to zero and exercise the refetch path without a fake
  /// clock. Five minutes, deliberately conservative: the site's own
  /// flow loads `/fulltext` once and submits the search from that
  /// page — often minutes later — so the server's token TTL cannot
  /// plausibly be shorter; inside the window the token is
  /// demonstrably still valid, beyond it reuse is refused and the
  /// token refetched, because a stale token answers HTTP 200 with
  /// the default listing, which the wrong-page echo guard cannot
  /// catch (a tokenless default listing echoes the query too —
  /// device-proven 2026-11-11).
  Duration get fulltextTokenMaxAge => const Duration(minutes: 5);

  /// Fetch the session's full-text token from the `/fulltext` page
  /// (or return the cached one). The token is required on every
  /// search request; a failure here fails the search with
  /// [fulltextTokenUnavailable] instead of silently falling back to
  /// normal search.
  ///
  /// No login gate here: the provider intercepts signed-out searches
  /// before the plugin is reached, and a fetch without a session
  /// simply finds no token on the page and fails the same way. The
  /// tests construct the API without a login and expect the fetch
  /// to run.
  Future<ApiResponse<String>> ensureFulltextToken() async {
    final cached = fulltextToken;
    if (cached != null) return ApiResponse.ok(cached);
    final raw = await _get(
      '/fulltext',
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? fulltextTokenUnavailable,
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? fulltextTokenUnavailable,
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    final token = extractFulltextToken(html);
    if (token == null) {
      return ApiResponse.fail(
        fulltextTokenUnavailable,
        statusCode: status,
      );
    }
    _fulltextToken = token;
    _fulltextTokenUserId = _userId;
    _fulltextTokenAt = DateTime.now();
    return ApiResponse.ok(token);
  }

  /// One page of full-text search results.
  ///
  /// The query form (`GET /fulltext/?q=…&token=…&type=…`) is used for
  /// every query — the path form (`/fulltext/{q}`) is not needed.
  /// `type` is `words` （按字搜索， the default: each word matches on
  /// its own) or `phrase` （按词搜索： the whole phrase must match);
  /// `exact` sends `e=1` （精确对应）. `order` is one of
  /// `popular` / `bestmatch` / `date` / `titleA` / `title` / `year` /
  /// `filesize` / `filesizeA` — note the site's `titleA` is A–Z and
  /// `title` is Z–A. Multi-value filters go out as repeated keys
  /// (`languages[]=chinese&languages[]=english`): the map keys here
  /// carry NO brackets and rely on the `ListFormat.multiCompatible`
  /// set on the request — Dio 5.9.2's default is `multi` (bare
  /// repeated keys), so the format must be explicit — the same form
  /// the eapi search already uses. Never combine a `languages[]`
  /// key with that format (it would emit `languages[][]=…`).
  ///
  /// A challenge page is reported as `HTTP 503: browser check page`
  /// (via [_looksLikeChallengePage]) so the caller can fall back to
  /// the WebView solver, exactly like the booklists screen does.
  /// When the failure looks like a stale token (login redirect,
  /// 401, or the token fetch itself failing), the cached token is
  /// dropped and the search is tried once more with a fresh one.
  ///
  /// Token reuse: a token fetched within [fulltextTokenMaxAge] is
  /// reused as-is — paging one search via loadMore, the next-page
  /// prefetch, a re-search seconds later — one round trip per page
  /// instead of two. Beyond the window it is refetched. The old rule
  /// fetched a fresh token for EVERY search and page after a stale
  /// one painted the wrong books (device-proven 2026-11-11: a stale
  /// token answers HTTP 200 with the default listing — the same 50
  /// books for any query — and the wrong-page echo guard cannot
  /// catch it, because a tokenless default listing echoes the query
  /// too). Bounding the REUSE by a short window keeps that failure
  /// mode out while dropping the extra round trip where it actually
  /// recurred: every page. When the server does reject a reused
  /// token, [_isStaleTokenFailure] still drops it and retries fresh.
  /// The cache is populated by this search's fetch either way, so
  /// the solver URL's [fulltextToken] getter reads the token fetched
  /// for THIS search.
  Future<ApiResponse<FullTextSearchPage>> searchFullText({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
  }) async {
    final fetchedAt = _fulltextTokenAt;
    final tokenUsable = fulltextToken != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < fulltextTokenMaxAge;
    if (!tokenUsable) {
      _fulltextToken = null;
      _fulltextTokenUserId = null;
      _fulltextTokenAt = null;
    }
    final capped = _capFulltextQuery(query);
    if (capped.trim().isEmpty) {
      return ApiResponse.fail('empty query');
    }
    final first = await _searchFullTextOnce(
      query: capped,
      type: type,
      exact: exact,
      yearFrom: yearFrom,
      yearTo: yearTo,
      languages: languages,
      extensions: extensions,
      order: order,
      page: page,
    );
    if (first.success || !_isStaleTokenFailure(first)) return first;
    _fulltextToken = null;
    _fulltextTokenUserId = null;
    _fulltextTokenAt = null;
    return _searchFullTextOnce(
      query: capped,
      type: type,
      exact: exact,
      yearFrom: yearFrom,
      yearTo: yearTo,
      languages: languages,
      extensions: extensions,
      order: order,
      page: page,
    );
  }

  /// A failure that smells like a stale token (and is worth one
  /// retry with a fresh token): the token fetch failed, the server
  /// redirected to login, or the session was rejected. A challenge
  /// page is NOT one — retrying it through Dio would hit the same
  /// wall; the caller handles that with the WebView solver.
  bool _isStaleTokenFailure(ApiResponse<FullTextSearchPage> response) {
    if (response.error == fulltextTokenUnavailable) return true;
    final status = response.statusCode;
    return status == 302 || status == 401;
  }

  Future<ApiResponse<FullTextSearchPage>> _searchFullTextOnce({
    required String query,
    required String type,
    required bool exact,
    required int? yearFrom,
    required int? yearTo,
    required List<String>? languages,
    required List<String>? extensions,
    required String? order,
    required int page,
  }) async {
    final tokenResponse = await ensureFulltextToken();
    final token = tokenResponse.data;
    if (!tokenResponse.success || token == null) {
      return ApiResponse.fail(
        tokenResponse.error ?? fulltextTokenUnavailable,
        statusCode: tokenResponse.statusCode,
      );
    }
    final raw = await _get(
      '/fulltext/',
      query: {
        'q': query,
        'token': token,
        'type': type,
        if (exact) 'e': '1',
        if (yearFrom != null) 'yearFrom': yearFrom,
        if (yearTo != null) 'yearTo': yearTo,
        if (languages != null && languages.isNotEmpty)
          'languages': languages,
        if (extensions != null && extensions.isNotEmpty)
          'extensions': extensions,
        if (order != null) 'order': order,
        'page': page,
      },
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'fulltext search failed',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'fulltext search failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    // The server answers a stale token with HTTP 200 and the default
    // listing instead of an error — the page is then a results page
    // for a different query (or none at all). The results form echoes
    // the submitted query in its `q` input; when it does not match
    // this search, fail as a stale token so the caller retries with
    // a fresh token instead of painting the wrong books.
    final echoedQuery = extractFulltextQuery(html);
    if (echoedQuery == null || echoedQuery != query.trim()) {
      return ApiResponse.fail(
        fulltextTokenUnavailable,
        statusCode: status,
      );
    }
    // Parse on a background isolate: a 50-hit page is a large HTML
    // document and the parse is pure work on a string; the result is
    // plain data (sendable), so the main isolate never blocks on it.
    final pageResult = await Isolate.run(
      () => parseFullTextSearchPage(html, baseUrl: _base),
    );
    return ApiResponse.ok(pageResult);
  }

  /// The full URL of one full-text results page — the string the
  /// app's screens use for their solver fallback (the WebView
  /// follows it with the session cookies installed).
  ///
  /// Unlike the Dio call, which passes bare `languages` keys and
  /// lets Dio's default list format add the brackets, a URL string
  /// has no such step: the keys here are written WITH brackets
  /// (`languages[]=…`) explicitly. [token] is the cached token when
  /// the caller has one; without it the server answers with the
  /// search form instead of results.
  String fulltextPageUrl({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
    String? token,
  }) {
    final capped = _capFulltextQuery(query);
    final parts = <String>[
      'q=${Uri.encodeComponent(capped)}',
      if (token != null) 'token=${Uri.encodeComponent(token)}',
      'type=${Uri.encodeComponent(type)}',
      if (exact) 'e=1',
      if (yearFrom != null) 'yearFrom=$yearFrom',
      if (yearTo != null) 'yearTo=$yearTo',
      if (languages != null)
        for (final language in languages)
          'languages[]=${Uri.encodeComponent(language)}',
      if (extensions != null)
        for (final extension in extensions)
          'extensions[]=${Uri.encodeComponent(extension)}',
      if (order != null) 'order=${Uri.encodeComponent(order)}',
      'page=$page',
    ];
    return '$_base/fulltext/?${parts.join('&')}';
  }

  static String _capFulltextQuery(String query) {
    return query.length > fulltextMaxQueryLength
        ? query.substring(0, fulltextMaxQueryLength)
        : query;
  }
}
