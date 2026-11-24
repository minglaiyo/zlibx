// Search & lists domain of [ZLibraryApi]: book search, detail,
// lists (most popular / recommended / recent / saved / downloaded),
// save/unsave, similar books, and comments. Split out of
// `zlibrary_api.dart` (item 7, step 2) as a mixin in the
// same library, `on ZLibraryApiBase`, so it can use the base
// class's private HTTP helpers (`_get`, `_postForm`, `_postText`,
// `_delete`) and session fields directly. The parsing helpers
// (`_booksOf`, `_metaOf`) moved to the base class in step 4,
// because `search` moved there too (both this mixin and the
// downloads mixin call it through the base); `_delete` moved to the
// base class with the booklists batch (the booklists domain uses it
// for unfavorite). The shared helpers (`_postText`,
// `_isInvalidHashError`) live in the base class because other
// domains use them too. A mixin in a separate library could not see
// those privates without changing the public interface (which the
// six test fakes implement).
part of 'zlibrary_api.dart';

/// Search, detail, lists, and comments methods for [ZLibraryApi].
mixin ZLibrarySearch on ZLibraryApiBase {
  // ── Search & lists ─────────────────────────────────────────────────

  /// Book search over the site's own HTML results route
  /// (`/s/{query}`) — the channel [ZLibraryApiBase.search]'s
  /// `POST /eapi/book/search` falls back to when the eapi search is
  /// unavailable.
  ///
  /// Why a second search channel exists at all: as of 2026-11-23 the
  /// eapi search route answers `400 Access denied` on every mirror
  /// tried, before credentials are even checked (a fake-cookie request
  /// to a live eapi route still answers `Invalid credentials`, so the
  /// rejection is the route's, not the session's). The HTML route is
  /// the site's own search and keeps answering; it is what the
  /// browser shows.
  ///
  /// [order] is the site's sort dropdown (`bestmatch`, `date`,
  /// `year`, `popular`, ...) passed through as-is. Filter parameter
  /// names are site-verified from the 2026-11-24 capture of the
  /// `/s/` form: it submits `['q', 'e', 'yearFrom', 'yearTo',
  /// 'languages[]', 'extensions[]']`, so [languages] / [extensions]
  /// ride on dio's `ListFormat.multiCompatible` list expansion
  /// exactly like the category and article routes. [exact] is the
  /// form's `e` checkbox. [page] is 1-based (`pagerOptions.baseUrl`
  /// is `/s/{query}?page=%number%`).
  ///
  /// There is deliberately no `limit`: the route has no page-size
  /// parameter — it renders ~51 cards per page (measured 2026-11-24)
  /// and ignores anything else. A caller that wants N books takes the
  /// first N of the page it gets.
  ///
  /// The books a page yields carry the webpage's 10-char short hash
  /// and a `/dl/{token}` link, never a 6-char eapi hash, so they must
  /// not be fed to the eapi detail endpoints (see
  /// [parseSearchBooksPage]'s field notes).
  ///
  /// A stale or wrong page is guarded the way the article search
  /// guards: the results form re-renders the submitted query in its
  /// `q` input and a mismatch fails the call instead of painting the
  /// wrong list. A browser-check wall is reported as
  /// `'HTTP $status: browser check page'` so the caller can hand the
  /// URL to the WebView solver (the app's `SearchHtmlRepository`).
  Future<ApiResponse<BookSearchPage>> searchBooksHtml({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
    CancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return ApiResponse.fail('book search: empty query');
    }
    // `_getWithRedirects`, not `_get`: `/s/` may hop (a slugged or
    // normalised search URL) and a non-following `_get` would answer
    // the 30x itself and fail the search.
    final raw = await _getWithRedirects(
      '/s/${Uri.encodeComponent(trimmed)}',
      queryParameters: {
        if (order != null) 'order': order,
        if (exact) 'e': '1',
        if (yearFrom != null) 'yearFrom': yearFrom,
        if (yearTo != null) 'yearTo': yearTo,
        if (languages != null && languages.isNotEmpty) 'languages': languages,
        if (extensions != null && extensions.isNotEmpty)
          'extensions': extensions,
        'page': page,
      },
      extraHeaders: const {'Accept': 'text/html'},
      cancelToken: cancelToken,
    );
    final status = raw.status;
    final html = raw.body;
    if (status == null || status < 200 || status >= 300) {
      return ApiResponse.fail(
        raw.error ?? 'book search failed',
        statusCode: status,
      );
    }
    if (html == null || html.isEmpty) {
      return ApiResponse.fail(raw.error ?? 'book search failed',
          statusCode: status);
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    final echoedQuery = extractSearchBooksQuery(html);
    if (echoedQuery == null || echoedQuery != trimmed) {
      return ApiResponse.fail('book search answered a different query',
          statusCode: status);
    }
    // Parse off the main isolate: a results page is ~190 KB of HTML
    // (measured 2026-11-24) and the parse is pure work on a string.
    final pageResult = await Isolate.run(
      () => parseSearchBooksPage(html, baseUrl: _base),
    );
    return ApiResponse.ok(pageResult);
  }

  /// The full URL of one book results page — the string the app's
  /// screens hand to the WebView solver, the same role the article
  /// route's `articlePageUrl` plays there. The filters mirror
  /// [searchBooksHtml].
  String searchBooksHtmlPageUrl({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
  }) {
    final trimmed = query.trim();
    final parts = <String>[
      if (order != null) 'order=${Uri.encodeComponent(order)}',
      if (exact) 'e=1',
      if (yearFrom != null) 'yearFrom=$yearFrom',
      if (yearTo != null) 'yearTo=$yearTo',
      for (final language in languages ?? const <String>[])
        'languages[]=${Uri.encodeComponent(language)}',
      for (final extension in extensions ?? const <String>[])
        'extensions[]=${Uri.encodeComponent(extension)}',
      'page=$page',
    ];
    return '$_base/s/${Uri.encodeComponent(trimmed)}?${parts.join('&')}';
  }

  /// Full detail for one book. [hashId] is the eapi hash from a search
  /// response; a webpage short hash (from booklist/profile HTML, or a
  /// shared-book link) is rejected with "Invalid hash".
  ///
  /// Hash shapes are device-verified (2026-11-21): eapi issues 6-char
  /// hashes, webpage short hashes are 10 chars (e.g. `5jJwz97pvp`).
  /// Two shortcuts keep an open cheap:
  ///  * a persisted resolve mapping (see `resolveCacheLookup` on the
  ///    base class) turns every repeat open into one call;
  ///  * a non-6-char hash with a [title] skips the doomed first call
  ///    and resolves up front — falling back to a direct fetch when
  ///    the resolve misses, which is never worse than the old
  ///    fail-then-resolve-then-retry chain.
  Future<ApiResponse<Book>> getBookInfo(
    String bookId,
    String hashId, {
    String? title,
  }) async {
    // 解析映射命中：直接用真 hash——省掉"短 hash 必失败的 fetch1"和
    // 按标题解析两个往返（2026-11-21 诊断：短 hash 书每次打开都白付
    // 三连发）。
    final mapped = await ZLibraryApiBase.resolveCacheLookup?.call(
      bookId,
      hashId,
    );
    final effective = (mapped == null || mapped.isEmpty) ? hashId : mapped;
    // 短 hash 检测（2026-11-21 实测定案）：eapi 只认自家 6 位 hash，
    // 网页短 hash 是 10 位（实机样本 5jJwz97pvp；书单/主页/分享链接
    // 只带这种）。疑似短 hash 就跳过"注定失败的 fetch1"直接解析——
    // 解析 miss 再退回原 hash 直取，最不济也是三连发的老路。误判代
    // 价有界：真有效的非 6 位 hash 会先解析再取，照样能取到书。
    final suspectShort =
        effective == hashId &&
        hashId.length != 6 &&
        title != null &&
        title.isNotEmpty;
    if (suspectShort) {
      final resolved = await resolveEapiHash(bookId, title);
      final target =
          (resolved == null || resolved.isEmpty) ? hashId : resolved;
      final response = await _fetchBookInfo(bookId, target);
      if (response.success &&
          resolved != null &&
          resolved.isNotEmpty &&
          resolved != hashId) {
        ZLibraryApiBase.resolveCacheWrite?.call(bookId, hashId, resolved);
      }
      return response;
    }
    final response = await _fetchBookInfo(bookId, effective);
    if (response.success) return response;
    if (title != null &&
        title.isNotEmpty &&
        ZLibraryApiBase._isInvalidHashError(response.error)) {
      final resolved = await resolveEapiHash(bookId, title);
      if (resolved != null && resolved != effective) {
        // 写回映射（键 = 传入的原始 hash——调用方每次都传原始值，
        // 映射坏了下次解析自然覆盖）。
        ZLibraryApiBase.resolveCacheWrite?.call(bookId, hashId, resolved);
        return _fetchBookInfo(bookId, resolved);
      }
    }
    return response;
  }

  /// Best-effort metadata for one book from its detail page HTML.
  /// [href] is the site-relative page path (`/book/{hash}/{slug}.html`
  /// as carried by list responses); an absolute URL is reduced to its
  /// path, anything else returns null.
  ///
  /// The eapi book object does not carry volume / ISBN / IPFS, so the
  /// detail page HTML is the only source. Thin delegate over
  /// [fetchBookDetailExtras] — same single fetch, returning the
  /// metadata; null when the fetch failed or the page carried no
  /// property rows.
  Future<BookDetailMetadata?> fetchBookDetailMetadata(String href) async {
    final response = await fetchBookDetailExtras(href);
    final metadata = response.success ? response.data?.metadata : null;
    return metadata == null || metadata.isEmpty ? null : metadata;
  }

  /// One best-effort fetch of the book detail page that parses the
  /// metadata rows ([BookDetailMetadata]) — the page's server-rendered
  /// property block (volume / ISBN / IPFS / rating), verified
  /// 2026-11-12 by fetching the raw document in a logged-out browser
  /// session.
  ///
  /// Returns [ApiResponse] rather than a nullable so the caller can
  /// tell a WALL from any other failure: the `/book/…` page sits
  /// behind the DiamWall, which answers a fresh client with 307 +
  /// `set-cookie: __diamwall=…` and — when the cookie hop is still
  /// untrusted — a `513` "Verifying your browser" JS challenge page
  /// (live-verified 2026-11-12 with a bare Dio client: hop 0 → 307,
  /// hop 1 with the cookie → 513). A challenge answer fails with the
  /// `'… browser check page'` error string the app's
  /// `BooklistSolver.isChallengeError` matches, so the caller can
  /// escalate to the WebView solver exactly like the booklists /
  /// full-text / category HTML routes do.
  Future<ApiResponse<BookDetailExtras>> fetchBookDetailExtras(
    String href,
  ) async {
    final page = await _fetchBookDetailPageHtml(href);
    if (!page.success) {
      return ApiResponse.fail(
        page.error ?? 'book detail page failed',
        statusCode: page.statusCode,
      );
    }
    final html = page.data!;
    // Phase 3: the host-injected Rust hook parses when present; the
    // Dart implementation stays as the fallback.
    final metadata = bookDetailParseOverride != null
        ? await bookDetailParseOverride!(html)
        : parseBookDetailProperties(html);
    // 关键词独立提取：Rust 钩子只负责 metadata 行，/terms/ 链接是
    // Dart-only 的一遍查询（site-verified 2026-11-19）。
    final keywords = parseBookDetailKeywords(html);
    // 关联书单同理：`z-booklist` 卡片是服务端渲染进同一文档的
    // （site-verified 2026-11-12），一次抓取顺带解析，无需额外请求。
    final relatedBooklists = parseRelatedBooklists(html, baseUrl: _base);
    // 非书页守卫（审查 v2 P2-11）：solver 腿先验 bookDetailsBox 才算
    // 书页，这条腿对 200 页不验——soft-404/重定向落到的非书 200 页会
    // 解析成全空 extras，被当成功回写、`booklists` 键在场即视为新鲜，
    // 空结果钉 7 天（关联书单页显示"没有书单"而非"失败重试"）。三样
    // 全空 = 不是书页。
    if (metadata.isEmpty && keywords.isEmpty && relatedBooklists.isEmpty) {
      return ApiResponse.fail('book detail page failed: not a book page');
    }
    return ApiResponse.ok(
      BookDetailExtras(
        metadata: metadata,
        keywords: keywords,
        relatedBooklists: relatedBooklists,
      ),
    );
  }

  /// One Dio fetch of a book's detail page, with the wall verdicts:
  /// the shared front half of every detail-page read
  /// ([fetchBookDetailExtras], [getBookInfoFromHtmlPage],
  /// [getSimilarBooksFromHtmlPage]) so all three agree on what a wall,
  /// a redirect and a dead page look like.
  ///
  /// `_getWithRedirects`, not `_get`: the detail page may hop (e.g. a
  /// canonical-URL redirect), and a non-redirect-following `_get` would
  /// answer the 30x itself and drop the rating. Same helper the article
  /// search and category pages use; it follows up to 5 hops, harvests
  /// the wall cookies a hop re-issues, and returns an error _Raw
  /// instead of throwing.
  ///
  /// 300s receive timeout, not the Dio default (60s): a detail page is
  /// a large HTML document (hundreds of KB), and on a slow link
  /// (~10 kB/s) it does not finish inside 60s — the fetch then fails
  /// silently and the rating vanishes while the small eapi book loads
  /// fine (device-verified 2026-11-12). Same 300s the downloads use for
  /// the same reason.
  Future<ApiResponse<String>> _fetchBookDetailPageHtml(String href) async {
    final path = Uri.tryParse(href)?.path ?? '';
    if (!path.startsWith('/book/')) {
      return ApiResponse.fail('book detail page failed: bad href');
    }
    final raw = await _getWithRedirects(
      path,
      extraHeaders: const {'Accept': 'text/html'},
      receiveTimeout: const Duration(seconds: 300),
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      final challengeish = status == 503 ||
          status == 513 ||
          (raw.body != null &&
              ZLibraryApiBase._looksLikeChallengePage(raw.body!));
      if (challengeish) {
        return ApiResponse.fail(
          'HTTP $status: browser check page',
          statusCode: status,
        );
      }
      return ApiResponse.fail(
        raw.error ?? 'book detail page failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      return ApiResponse.fail('book detail page failed: empty body');
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    return ApiResponse.ok(html);
  }

  /// The book itself, read off its own detail page — the fallback for
  /// [getBookInfo] when the caller's hash is a webpage short hash.
  ///
  /// Why the page has to be able to describe the book at all: eapi
  /// wants its own 6-character hash and HTML only ever carries the
  /// 10-character short one (site-verified 2026-11-24 — and this time
  /// against a KNOWN pair: book 24126585's eapi hash `217fd6` appears
  /// nowhere in that book's `/s/` result card or detail page, and a
  /// same-length-but-wrong hash is rejected exactly like a short one,
  /// so the value is a real per-book secret, not a format check).
  /// `/json/search`, `/json/get-book`, `/api/get-book/` and
  /// `/papi/book/search` were probed the same day and every one of
  /// them answers HTML or `Requested page not found` — no route left
  /// on the webpage maps an id to an eapi hash. A book that reached
  /// the app through HTML therefore has no eapi detail call, and this
  /// is the channel that fills the screen.
  ///
  /// Wall contract identical to [fetchBookDetailExtras]: a challenge
  /// answer fails as `'HTTP $status: browser check page'` so the app's
  /// repository can escalate to the WebView solver.
  Future<ApiResponse<Book>> getBookInfoFromHtmlPage(String href) async {
    final page = await _fetchBookDetailPageHtml(href);
    if (!page.success) {
      return ApiResponse.fail(
        page.error ?? 'book detail page failed',
        statusCode: page.statusCode,
      );
    }
    final html = page.data!;
    final baseUrl = _base;
    final book = await Isolate.run(
      () => parseBookDetailPage(html, baseUrl: baseUrl, href: href),
    );
    if (book == null) {
      return ApiResponse.fail('book detail page failed: not a book page');
    }
    return ApiResponse.ok(book);
  }

  /// The detail page's own 相似书籍 block — the fallback for [similar]
  /// under the same hash condition as [getBookInfoFromHtmlPage].
  ///
  /// An empty list is a legitimate answer here (a book the site has no
  /// recommendations for renders no `books-mosaic`), so unlike the
  /// detail-body path this must not turn "no rows" into a failure: the
  /// caller distinguishes fetch failure from an empty shelf by
  /// [ApiResponse.success].
  Future<ApiResponse<List<Book>>> getSimilarBooksFromHtmlPage(
    String href,
  ) async {
    final page = await _fetchBookDetailPageHtml(href);
    if (!page.success) {
      return ApiResponse.fail(
        page.error ?? 'book detail page failed',
        statusCode: page.statusCode,
      );
    }
    final html = page.data!;
    final baseUrl = _base;
    final books = await Isolate.run(
      () => parseBookDetailRecommendations(html, baseUrl: baseUrl),
    );
    return ApiResponse.ok(books);
  }

  /// Resolve the real eapi hash for a book whose stored hash is a
  /// webpage short hash: search by title and take the hash of the
  /// result with the same numeric id. Returns null when the search
  /// fails or no result matches. The search response is the only
  /// place the eapi hash appears — booklist/profile HTML and the
  /// get-books JSON carry only the short URL hash.

  Future<ApiResponse<Book>> _fetchBookInfo(
    String bookId,
    String hashId,
  ) async {
    final raw = await _get('/eapi/book/$bookId/$hashId');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'book info failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ?? 'book info failed',
        statusCode: raw.status,
      );
    }
    final bookJson = json['book'];
    if (bookJson is Map<String, dynamic>) {
      return ApiResponse.ok(Book.fromJson(bookJson));
    }
    // Some endpoints return the book fields at the top level.
    if (json['title'] != null) {
      return ApiResponse.ok(Book.fromJson(json));
    }
    return ApiResponse.fail('book info response had no book',
        statusCode: raw.status);
  }

  /// Homepage "most popular". Both spellings are tried — the real
  /// endpoint is the hyphenated `/eapi/book/most-popular`
  /// (device-verified 2026-11-20 on bookroom.lifestyle: success:1 with
  /// books; the underscore spelling this plugin historically used
  /// answers 400 there, so the home list silently lived on the
  /// popularity-ordered search fallback); community mirrors may only
  /// know either. If the server 404s it, rejects it, or returns an
  /// empty list, fall back to a popularity-ordered search so the home
  /// list still works. (The community mirrors answer this endpoint with
  /// success:0 / an empty payload instead of 404, so a 404-only
  /// fallback leaves the home screen blank — device-verified 2026-11-05
  /// on the run #6 package.)
  Future<ApiResponse<List<Book>>> getMostPopular({int? page}) async {
    for (final path in const [
      '/eapi/book/most-popular',
      '/eapi/book/most_popular',
    ]) {
      final raw = await _get(
        path,
        query: page != null ? {'page': page} : null,
      );
      // A blocked line would make the search fallback fail too — chaining
      // it only burns 2×15s more of timeouts before surfacing the same
      // "cf_blocked". The device-verified fallback for success:0/empty
      // payloads below is intentional and stays.
      if (raw.error == 'cf_blocked') {
        return ApiResponse.fail('cf_blocked', statusCode: raw.status);
      }
      // 404 / 无 body / success:0 / 空列表：四种情况都算这个拼写不行，
      // 换下一个（社区镜像常用 success:0 或空 payload 回答本接口）。
      final json = raw.json;
      final books = json == null
          ? const <Book>[]
          : await ZLibraryApiBase.booksOfH(json, rawBody: raw.body);
      final usable =
          raw.status != 404 &&
          json != null &&
          ZLibraryApiBase._isSuccess(json) &&
          books.isNotEmpty;
      if (usable) {
        return ApiResponse.ok(books, meta: ZLibraryApiBase._metaOf(json));
      }
    }
    return search(order: 'popular', limit: 20, page: page);
  }

  /// Personalised home recommendations.
  ///
  /// There is deliberately no most-popular fallback here (用户 2026-11-15
  /// 定：与热门页冲突了）。之前 404 / 空 / success:0 全都会静默改走
  /// [getMostPopular]，首页拿到的是热门推荐却显示成"为你推荐"，跟独立
  /// 的热门页内容一模一样。现在两类分开：
  /// - 请求本身没成（cf_blocked / 404 / 无 body / success:0）→ 失败，
  ///   首页显示错误 + 重试入口。
  /// - 请求成功但列表为空 → 空列表（新账号没有历史，这是合法结果），
  ///   首页显示空状态，不报错也不兜底。
  Future<ApiResponse<List<Book>>> getUserRecommended() async {
    // Path verified against heartleo/zlib's eapi_feed.go (2026-11-12):
    // the personalised feed lives under /eapi/user/book/recommended.
    // The earlier /eapi/user/recommended (no /book/) 404s — that is
    // what issue #3's diagnostic proved on device (http-404 fallback).
    final raw = await _get('/eapi/user/book/recommended');
    // Same cf_blocked short-circuit as [getMostPopular].
    if (raw.error == 'cf_blocked') {
      return ApiResponse.fail('cf_blocked', statusCode: raw.status);
    }
    if (raw.status == 404 || raw.json == null) {
      return ApiResponse.fail(
        raw.error ?? 'recommendations failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'recommendations failed',
        statusCode: raw.status,
      );
    }
    // success:1 with no books — an empty personalised feed, not a
    // failure. Returned as-is so the UI can tell the two apart.
    return ApiResponse.ok(
      await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body),
      meta: <String, dynamic>{...?ZLibraryApiBase._metaOf(raw.json!)},
    );
  }

  /// Recently added books. The `/eapi/book/recently` endpoint only
  /// returns `success=1` with no `books` array (heartleo research:
  /// do not treat `recently` as a usable list), so an empty payload
  /// falls back to a date-ordered search — same as [getMostPopular]
  /// falling back on empty. `date` is the server's real "Recently
  /// added" sort value; `newest` is not a valid order (an invalid
  /// value silently degrades to popular).
  Future<ApiResponse<List<Book>>> getRecently({int? page}) async {
    final raw = await _get(
      '/eapi/book/recently',
      query: page != null ? {'page': page} : null,
    );
    // Same cf_blocked short-circuit as [getMostPopular]: the search
    // fallback cannot succeed on a blocked line either.
    if (raw.error == 'cf_blocked') {
      return ApiResponse.fail('cf_blocked', statusCode: raw.status);
    }
    if (raw.status == 404) {
      return search(order: 'date', limit: 20, page: page);
    }
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'recently failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'recently failed',
        statusCode: raw.status,
      );
    }
    final books = await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body);
    if (books.isEmpty) {
      return search(order: 'date', limit: 20, page: page);
    }
    return ApiResponse.ok(books, meta: ZLibraryApiBase._metaOf(raw.json!));
  }

  Future<ApiResponse<List<Book>>> getUserSaved({
    int? page,
    int? limit,
  }) async {
    final raw = await _get(
      '/eapi/user/book/saved',
      query: {
        if (page != null) 'page': page,
        if (limit != null) 'limit': limit,
      },
    );
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'saved books failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'saved books failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(
        await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body),
        meta: ZLibraryApiBase._metaOf(raw.json!));
  }

  Future<ApiResponse<List<Book>>> getUserDownloaded({
    int? page,
    int? limit,
  }) async {
    final raw = await _get(
      '/eapi/user/book/downloaded',
      query: {
        if (page != null) 'page': page,
        if (limit != null) 'limit': limit,
      },
    );
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'downloaded books failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'downloaded books failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(
        await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body),
        meta: ZLibraryApiBase._metaOf(raw.json!));
  }

  /// Save to "My library". Mirrors the confirmed unsave path.
  Future<ApiResponse<void>> saveBook(String bookId) async {
    final raw = await _get('/eapi/user/book/$bookId/save');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'save failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'save failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(null);
  }

  /// Confirmed path from the public eapi clients.
  Future<ApiResponse<void>> unsaveUserBook(String bookId) async {
    final raw = await _get('/eapi/user/book/$bookId/unsave');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'unsave failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'unsave failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(null);
  }

  /// Books similar to one book. Falls back to a title search on 404.
  Future<ApiResponse<List<Book>>> similar(
    String bookId,
    String hashId,
  ) async {
    final raw = await _get('/eapi/book/$bookId/$hashId/similar');
    if (raw.status == 404) {
      final info = await getBookInfo(bookId, hashId);
      if (!info.success || info.data == null) {
        return ApiResponse.fail(
          info.error ?? 'similar failed',
          statusCode: info.statusCode,
        );
      }
      final res = await search(message: info.data!.title, limit: 20);
      if (!res.success) return res;
      final books =
          res.data!.where((b) => b.id.toString() != bookId).toList();
      return ApiResponse.ok(books, meta: res.meta);
    }
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'similar failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'similar failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(
        await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body),
        meta: ZLibraryApiBase._metaOf(raw.json!));
  }

  /// Book comments, view-only. The site's own `papi/` JSON API, NOT eapi:
  /// `GET /papi/comments/book/{bookId}/{page}?limit={limit}`.
  /// Confirmed by a packet capture on 2026-11-06 (zh.z-library.sk book
  /// page): `success: 1`, a `comments` array, a `commentsDisabled` flag.
  /// Auth is the same remix session cookies the eapi calls send; the
  /// endpoint needs a logged-in session. Page is 0-based; there is no
  /// total/pages field, so callers page until a short page arrives.
  Future<ApiResponse<BookCommentsPage>> getBookComments(
    String bookId, {
    int page = 0,
    int limit = 50,
  }) async {
    final raw = await _get('/papi/comments/book/$bookId/$page?limit=$limit');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'comments failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ?? 'comments failed',
        statusCode: raw.status,
      );
    }
    if (json['commentsDisabled'] == true) {
      return ApiResponse.ok(
          const BookCommentsPage(comments: [], disabled: true));
    }
    final list = json['comments'];
    if (list is! List) {
      return ApiResponse.fail('comments response had no list',
          statusCode: raw.status);
    }
    final reactions = commentReactionsOf(json);
    return ApiResponse.ok(BookCommentsPage(
      comments: list
          .whereType<Map<String, dynamic>>()
          .map((c) => BookComment.fromJson(c, baseUrl: _base))
          .map((c) {
            final r = reactions[c.id];
            return r == null
                ? c
                : c.copyWith(likeCount: r.count, isLiked: r.liked);
          })
          .toList(),
    ));
  }

  /// The signed-in user's own posted comments, as the website shows them
  /// on the profile Comments tab:
  /// `GET /papi/comments/user/{userId}/{page}?limit={limit}`.
  /// Confirmed by a packet capture on 2026-11-06 (zh.z-library.sk
  /// profile page): `success: 1`, `comments` as a MAP keyed by comment
  /// id (not a list), `commentsTitles: {book: {...}}` with each
  /// comment's book title, plus `reactionsInfo`/`reactionsUsers`.
  /// Page is 0-based; the site fetches limit 500 for the whole
  /// collection in one go. Auth is the remix session cookies.
  Future<ApiResponse<UserCommentsPage>> getMyComments({
    int page = 0,
    int limit = 500,
  }) async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      return ApiResponse.fail('not logged in');
    }
    return _fetchUserCommentsPage(userId, page, limit);
  }

  /// Another user's posted comments, same endpoint as [getMyComments]
  /// but for an arbitrary user id (the id comes from a tapped
  /// comment's `user_id`). Same page/limit semantics; the viewer
  /// still needs a logged-in session (remix cookies).
  Future<ApiResponse<UserCommentsPage>> getUserComments(
    String userId, {
    int page = 0,
    int limit = 500,
  }) async {
    if (userId.isEmpty) {
      return ApiResponse.fail('missing user id');
    }
    return _fetchUserCommentsPage(userId, page, limit);
  }

  Future<ApiResponse<UserCommentsPage>> _fetchUserCommentsPage(
    String userId,
    int page,
    int limit,
  ) async {
    final raw = await _get('/papi/comments/user/$userId/$page?limit=$limit');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'my comments failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ??
            'my comments failed',
        statusCode: raw.status,
      );
    }
    final map = json['comments'];
    if (map is! Map) {
      return ApiResponse.fail('my comments response had no map',
          statusCode: raw.status);
    }
    final reactions = commentReactionsOf(json);
    final titles = commentTitlesOf(json);
    final entries = <UserCommentEntry>[];
    for (final value in map.values) {
      if (value is! Map<String, dynamic>) continue;
      final bookId = value['object_id'] is int
          ? value['object_id'] as int
          : int.tryParse('${value['object_id']}') ?? 0;
      final comment = BookComment.fromJson(value, baseUrl: _base);
      final r = reactions[comment.id];
      entries.add(UserCommentEntry(
        comment: r == null
            ? comment
            : comment.copyWith(likeCount: r.count, isLiked: r.liked),
        bookId: bookId,
        bookTitle: titles[bookId] ?? '',
      ));
    }
    return ApiResponse.ok(UserCommentsPage(entries: entries));
  }

  /// Post a book comment, or a reply when [parentId] is set. The site's
  /// own `papi/` JSON API: `POST /papi/comments/add` with a JSON body
  /// (`hash`, `object: "book"`, `object_id` as a STRING, `text`, plus
  /// `parent_id` for replies), sent as `text/plain`. Confirmed by a
  /// packet capture on 2026-11-06: the first request answers 307 to the
  /// same URL and the follow-up returns 200
  /// `{success: 1, comment: {...}, currentUser: {...}}` — the new
  /// comment comes back in the same shape as the read list, so callers
  /// can insert it directly. Auth is the remix session cookies.
  Future<ApiResponse<BookComment>> postBookComment(
    String bookId, {
    required String text,
    String? parentId,
  }) async {
    final body = <String, dynamic>{
      'hash': '',
      'object': 'book',
      'object_id': bookId,
      'text': text,
    };
    if (parentId != null) body['parent_id'] = parentId;
    final raw = await _postText('/papi/comments/add', jsonEncode(body));
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'post comment failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ??
            'post comment failed',
        statusCode: raw.status,
      );
    }
    final comment = json['comment'];
    if (comment is! Map<String, dynamic>) {
      return ApiResponse.fail('post comment had no comment',
          statusCode: raw.status);
    }
    return ApiResponse.ok(BookComment.fromJson(comment, baseUrl: _base));
  }

  /// Like ([like] true) or unlike a comment. `POST
  /// /papi/comments/like/{commentId}/{1|0}` with an empty JSON body,
  /// confirmed by a packet capture on 2026-11-06 (same 307-to-same-URL
  /// hop as posting). The 200 answer carries the comment's new like
  /// state (`likes` + `isLiked` arrays) in the same shape as the read
  /// page's `reactionsInfo`.
  Future<ApiResponse<CommentLikeResult>> likeBookComment(
    int commentId, {
    required bool like,
  }) async {
    final raw = await _postText(
      '/papi/comments/like/$commentId/${like ? 1 : 0}',
      '{}',
    );
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'like failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ?? 'like failed',
        statusCode: raw.status,
      );
    }
    final result = CommentLikeResult.fromLikeJson(json, commentId);
    if (result == null) {
      return ApiResponse.fail('like response had no update',
          statusCode: raw.status);
    }
    return ApiResponse.ok(result);
  }

  /// Delete one of the signed-in user's own comments. `DELETE
  /// /papi/comments/delete/{commentId}` with no request body,
  /// confirmed by a packet capture on 2026-11-09 (Firefox,
  /// zh.z-library.sk): HTTP 200 with `{"success": 1}`.
  ///
  /// The capture's Payload tab was not shown, so "no body" is an
  /// assumption from the id-in-path shape and the sibling endpoints
  /// (like posts an empty JSON body); device testing will confirm it.
  Future<ApiResponse<bool>> deleteBookComment(int commentId) async {
    final raw = await _delete('/papi/comments/delete/$commentId');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'delete comment failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ??
            'delete comment failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(true);
  }

}
