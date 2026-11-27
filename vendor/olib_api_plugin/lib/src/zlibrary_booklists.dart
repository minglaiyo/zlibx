// Booklists domain of [ZLibraryApi]: public/my booklists, list
// detail, create/add/remove/delete lists, and the readlist entry
// id lookup. Split out of `zlibrary_api.dart` (item 7, step 3)
// as a mixin in the same library, `on ZLibraryApiBase`, so it can
// use the base class's private HTTP helpers (`_get`, `_postForm`,
// `_postText`, `_getWithRedirects`) directly. The
// `onBooklistHtmlLoaded` callback moved here with the block because
// only this domain uses it. A mixin in a separate library could not
// see those privates without changing the public interface (which the
// six test fakes implement).
// Split further (review-2 P1-4): the write endpoints moved to
// `zlibrary_booklist_writes.dart` and the membership endpoints to
// `zlibrary_booklist_membership.dart`; this file keeps the reads.
part of 'zlibrary_api.dart';

/// Booklist read methods for [ZLibraryApi].
mixin ZLibraryBooklists on ZLibraryApiBase {
  /// Called with the raw HTML of every booklist page the plugin loads
  /// successfully over Dio (list pages, profile page, detail page 1).
  /// The app registers a handler that persists it for its
  /// stale-while-revalidate cache; the plugin itself never stores
  /// anything. The URL is the page's canonical URL (the same string
  /// the app's screens use for their solver and cache keys), never
  /// the raw request URL. Null means no handler.
  ///
  /// [fetchedAt] is when the request started: the handler drops the
  /// page when a write (add/remove a book) invalidated the URL after
  /// the fetch started, so a stale page cannot re-enter the cache
  /// after an invalidation (see BooklistHtmlCache).
  void Function(String url, String html, DateTime fetchedAt)?
      onBooklistHtmlLoaded;


  // ── Booklists ──────────────────────────────────────────────────────

  /// Public booklists, read-only. The site's own list page
  /// (`GET /booklists?searchQuery={q}&order={order}&page={n}`) is HTML:
  /// `<z-booklist>` elements, parsed by [parseBooklistsPage].
  /// [order] is `popular` (default), `date_created` or `date_updated`.
  /// Page is 1-based. Shapes come from the public sertraline/zlibrary
  /// client (read as a shape reference only — no code copied) and are
  /// NOT yet live-verified; the list HTML may drift. Needs a logged-in
  /// session like the rest of the site's pages.
  Future<ApiResponse<BooklistsPage>> searchPublicBooklists({
    String query = '',
    String order = 'popular',
    int page = 1,
  }) async {
    return _searchBooklists(
      '/booklists',
      query: query,
      order: order,
      page: page,
    );
  }

  /// The signed-in user's own booklists, read-only
  /// (`GET /booklists/my?searchQuery={q}&order={order}&page={n}`, same
  /// HTML shape as the public list). Same verification status as
  /// [searchPublicBooklists]. [order] is omitted when null (the
  /// site's default order).
  Future<ApiResponse<BooklistsPage>> searchMyBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    return _searchBooklists(
      '/booklists/my',
      query: query,
      order: order,
      page: page,
    );
  }

  /// The favorite booklists of the signed-in user
  /// (`GET /booklists/favorite?searchQuery={q}&page={n}`) — the
  /// site's "最喜欢的书单" nav entry (site-verified 2026-11-19: the
  /// link is in the /booklists header even logged out; the page
  /// itself needs the session). Same `<z-booklist>` HTML shape as
  /// the public and own list pages, parsed identically. [order] is
  /// omitted when null (this page's own default order).
  Future<ApiResponse<BooklistsPage>> searchFavoriteBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    return _searchBooklists(
      '/booklists/favorite',
      query: query,
      order: order,
      page: page,
    );
  }

  /// Absolute URL of a booklist list page, for callers that fetch the
  /// HTML themselves (e.g. through the WebView challenge solver when
  /// the mirror walls Dio with a 503 browser-check page). Same path +
  /// query construction as [_searchBooklists] — the app must not
  /// rebuild it. [favorite] selects the favorites page (mutually
  /// exclusive with [mine]; favorite wins when both are set).
  String booklistsPageUrl({
    required bool mine,
    bool favorite = false,
    String query = '',
    String? order,
    int page = 1,
  }) {
    final path = favorite
        ? '/booklists/favorite'
        : mine
        ? '/booklists/my'
        : '/booklists';
    final uri = Uri.parse('$_base$path').replace(
      queryParameters: _booklistListParams(
        query: query,
        order: order,
        page: page,
      ).map((key, value) => MapEntry(key, value.toString())),
    );
    return uri.toString();
  }

  /// Query parameters of a booklist list page, shared by
  /// [_searchBooklists] and [booklistsPageUrl] so the two
  /// constructions cannot drift apart.
  static Map<String, dynamic> _booklistListParams({
    required String query,
    String? order,
    required int page,
  }) {
    final params = <String, dynamic>{
      'searchQuery': query,
      'page': page,
    };
    if (order != null) params['order'] = order;
    return params;
  }

  Future<ApiResponse<BooklistsPage>> _searchBooklists(
    String path, {
    required String query,
    String? order,
    required int page,
  }) async {
    final params = _booklistListParams(
      query: query,
      order: order,
      page: page,
    );
    // When this fetch started, for the handler's invalidation check.
    final fetchedAt = DateTime.now();
    // Call [_get] directly so a failure can report its real cause:
    // the old code collapsed every failure into a bare
    // "booklists failed", which hid whether the page 302'd, hit a wall,
    // timed out, or came back as JSON. The `Accept: text/html` override
    // is needed because the shared Dio default is `application/json`,
    // and the site answers a page route asked for as JSON with JSON
    // (or an error) instead of the page.
    final raw = await _get(
      path,
      query: params,
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'booklists failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'booklists failed',
        statusCode: status,
      );
    }
    // A 200 answer can still be the wall (challenge page with a 200
    // status): it parses to an empty list, which would look like "no
    // booklists". Fail loudly instead so the caller can fall back to
    // the WebView solver like it does for the 503 case.
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    onBooklistHtmlLoaded?.call(
      booklistsPageUrl(
        mine: path == '/booklists/my',
        // 收藏页的缓存键必须带上 favorite（审查 P1-1）：漏传会写进发现
        // 页的键——收藏 tab 的 SWR 永不命中，且默认参数下两个 tab 互写
        // 同一个键，私密收藏会画进公共的发现页。
        favorite: path == '/booklists/favorite',
        query: query,
        order: order,
        page: page,
      ),
      html,
      fetchedAt,
    );
    return ApiResponse.ok(await parseBooklistsPageH(html, baseUrl: _base));
  }

  /// Absolute URL of a user's profile page, for callers that fetch the
  /// HTML themselves (e.g. through the WebView challenge solver when
  /// the mirror walls Dio). Same path construction as
  /// [getUserProfileBooklists] — the app must not rebuild it.
  String userProfilePageUrl({
    required String userId,
    required String userHash,
  }) {
    return '$_base/profile/$userId/$userHash';
  }

  /// Booklists on one user's profile page, from the profile document
  /// (`GET /profile/{userId}/{hash}` — one HTML document carrying
  /// every tab, with the booklists tab server-rendered as
  /// `<z-booklist>` elements; see [parseUserProfileBooklists]).
  /// [userHash] is the profile hash from a comment's `user.hash`
  /// (NOT the avatar filename suffix). Empty list when the user has
  /// no booklists. The profile page is an HTML route, so like the
  /// list pages it can answer with the browser-check wall — reported
  /// as `HTTP 503: browser check page` so the caller can fall back
  /// to the WebView solver.
  ///
  /// The tab renders at most 10 lists per document (issue #11):
  /// users with more carry a paginator, and [UserProfileBooklistsPage.pagesTotal]
  /// reports the largest page the page-1 paginator reveals — a LOWER
  /// bound, not the real total: the paginator is a sliding window
  /// (page 1 shows 1–10, no Last link), so the real total can exceed
  /// it (issue #34: a 71-page profile reads as 10 from page 1).
  /// Callers must fetch pages sequentially until a page is empty or
  /// partial, not stop at [UserProfileBooklistsPage.pagesTotal] (see
  /// `UserProfileScreen._loadBooklistPages2Plus`). Page 1 of the
  /// paginated route is this same document.
  Future<ApiResponse<UserProfileBooklistsPage>> getUserProfileBooklists({
    required String userId,
    required String userHash,
  }) async {
    if (userId.isEmpty) {
      return ApiResponse.fail('missing user id');
    }
    if (userHash.isEmpty) {
      return ApiResponse.fail('missing profile hash');
    }
    // When this fetch started, for the handler's invalidation check.
    final fetchedAt = DateTime.now();
    final raw = await _get(
      '/profile/$userId/$userHash',
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'profile booklists failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'profile booklists failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    onBooklistHtmlLoaded?.call(
      userProfilePageUrl(userId: userId, userHash: userHash),
      html,
      fetchedAt,
    );
    final lists = await parseUserProfileBooklistsH(html, baseUrl: _base);
    return ApiResponse.ok(
      UserProfileBooklistsPage(
        lists: lists,
        pagesTotal: parseUserProfileBooklistsPagesTotal(html),
      ),
    );
  }

  /// Absolute URL of one paginated document of a user's profile
  /// booklists (`/profile/{userId}/{hash}/booklists?page=N`), for
  /// callers that fetch the HTML themselves. Page 1 omits the query
  /// (the bare `/booklists` path serves it too — same document as
  /// [userProfilePageUrl], live-verified 2026-11-21). Same path
  /// construction as [getUserProfileBooklistsPage] — the app must
  /// not rebuild it.
  String userProfileBooklistsPageUrl({
    required String userId,
    required String userHash,
    required int page,
  }) {
    final path = '$_base/profile/$userId/$userHash/booklists';
    return page <= 1 ? path : '$path?page=$page';
  }

  /// One paginated document (page ≥ 2) of a user's profile booklists:
  /// `GET /profile/{userId}/{hash}/booklists?page=N` — the same full
  /// profile document shape, with the booklists tab rendering the
  /// next ≤ 10 lists and its own paginator (live-verified 2026-11-21,
  /// issue #11: the profile document only renders the first 10).
  /// Page 1 is served by [getUserProfileBooklists] (the profile
  /// document itself). Like it, this route can answer with the
  /// browser-check wall — reported as `HTTP 503: browser check page`
  /// so the caller can fall back to the WebView solver for page 1
  /// (whose solve clears the wall cookies Dio then reuses).
  ///
  /// The loaded HTML is NOT handed to [onBooklistHtmlLoaded]: the app
  /// only re-reads the profile document (page 1) from its cache, so
  /// caching page-N documents would just be dead data.
  Future<ApiResponse<List<Booklist>>> getUserProfileBooklistsPage({
    required String userId,
    required String userHash,
    required int page,
  }) async {
    if (userId.isEmpty) {
      return ApiResponse.fail('missing user id');
    }
    if (userHash.isEmpty) {
      return ApiResponse.fail('missing profile hash');
    }
    if (page <= 1) {
      return ApiResponse.fail('profile booklists page must be ≥ 2');
    }
    // `_get` prefixes `_base` itself, so pass the host-relative path
    // (the absolute URL lives in [userProfileBooklistsPageUrl] for
    // callers that fetch the page themselves).
    final raw = await _get(
      '/profile/$userId/$userHash/booklists?page=$page',
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'profile booklists failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'profile booklists failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    return ApiResponse.ok(await parseUserProfileBooklistsH(html, baseUrl: _base));
  }

  /// Books on the FIRST page of one booklist, parsed from the detail
  /// page's own HTML (`/booklist/{id}/{hash}/{slug}.html`, via
  /// [parseBooklistDetailBooks]).
  ///
  /// Page 1 is never served by the JSON endpoint (see
  /// [getBooklistBooks]) — it is server-rendered into the detail
  /// document as `<z-bookcard>` elements. The detail page is an HTML
  /// route, so like the list pages it can answer with the browser-check
  /// wall: a challenge page is reported as `HTTP 503: browser check
  /// page` (via `_looksLikeChallengePage`) so the caller can fall back
  /// to the WebView solver, exactly like the booklists screen does.
  /// The request stays on the current mirror (only the path of
  /// [Booklist.url] is used) and carries the session Cookie.
  Future<ApiResponse<List<Book>>> getBooklistDetailBooks(
    Booklist list,
  ) async {
    final path = Uri.tryParse(list.url)?.path ?? '';
    if (path.isEmpty) {
      return ApiResponse.fail('booklist has no page url');
    }
    // When this fetch started, for the handler's invalidation check.
    final fetchedAt = DateTime.now();
    // Call [_get] directly so a failure can report
    // its real cause, like [_searchBooklists] does.
    final raw = await _get(
      path,
      extraHeaders: const {'Accept': 'text/html'},
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'booklist failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(
        raw.error ?? 'booklist failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    onBooklistHtmlLoaded?.call(list.url, html, fetchedAt);
    return ApiResponse.ok(await parseBooklistDetailBooksH(html, baseUrl: _base));
  }

  /// Books on page 2 and up of one booklist. The site's own JSON API:
  /// `GET /papi/booklist/{id}/get-books/{page}` answers
  /// `{books: [{book: {...}}], pagination: {total_pages}}`; each inner
  /// `book` maps through [Book.fromJson] (its `href` supplies the
  /// `hash`, which the JSON itself does not carry). The `{id}` is the
  /// NUMERIC list id — the site's own `loadMoreBooks`
  /// (z-booklists-browser.js, captured 2026-11-07) calls exactly this
  /// URL. Pages start at 2: the site's counter starts at 1 and is
  /// incremented before the fetch, so page 1 is never requested — it
  /// is server-rendered into the detail document (see
  /// [getBooklistDetailBooks]), and asking the endpoint for page 1
  /// answers "Requested page not found" (verified on device
  /// 2026-11-07 for both the numeric id and the href hash — the
  /// hash-key theory was wrong). Pass the list's numeric [Booklist.id].
  Future<ApiResponse<BooklistBooksPage>> getBooklistBooks(
    String id, {
    int page = 2,
  }) async {
    final raw = await _get('/papi/booklist/$id/get-books/$page');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'booklist failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ?? 'booklist failed',
        statusCode: raw.status,
      );
    }
    final list = json['books'];
    if (list is! List) {
      return ApiResponse.fail('booklist response had no books',
          statusCode: raw.status);
    }
    final books = list
        .whereType<Map<String, dynamic>>()
        .map((e) => e['book'])
        .whereType<Map<String, dynamic>>()
        .map(Book.fromJson)
        .toList();
    final pagination = json['pagination'];
    // 分页仲裁（2026-11-21 用户实测：所有书单第 1 页 20 本后直接收口
    // ——部分线路的 papi 响应不带 pagination 字段，旧代码按"共 1 页"
    // 处理）。字段缺席时不再按 1 页收口：改按页大小启发——本页满
    // 20 本就假定还有下一页（totalPages 设为 page+1，page < totalPages
    // 即 hasMore），短页/空页才是末页。字段在场时照旧精确仲裁。
    int totalPages;
    if (pagination is Map<String, dynamic>) {
      final rawTotal = pagination['total_pages'];
      totalPages = rawTotal is int
          ? rawTotal
          : int.tryParse(rawTotal.toString()) ?? 1;
    } else {
      totalPages = books.length >= 20 ? page + 1 : page;
    }
    return ApiResponse.ok(
      BooklistBooksPage(books: books, totalPages: totalPages),
    );
  }

  /// Recommended booklists for a category slot: `POST
  /// /papi/booklist/get-from-category` with `{categoryId, languages,
  /// booklistsCount}`. The site calls it with an empty category id and
  /// the string `'false'` for languages to fill its
  /// `.booklist-recommendations-content` slots; the answer's `html`
  /// array carries one JSON object per list. [booklistsCount] is how
  /// many slots the caller has to fill.
  Future<ApiResponse<List<Booklist>>> getRecommendedBooklists({
    int booklistsCount = 10,
  }) async {
    final raw = await _postText(
      '/papi/booklist/get-from-category',
      jsonEncode({
        'categoryId': '',
        'languages': 'false',
        'booklistsCount': booklistsCount,
      }),
    );
    final json = raw.json;
    if (json == null) {
      return ApiResponse.fail(
        raw.error ?? 'recommended booklists failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'recommended booklists failed',
        ),
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(
      parseRecommendedBooklists(json['html'], baseUrl: _base),
    );
  }
}
