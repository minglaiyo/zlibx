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
part of 'zlibrary_api.dart';

/// Booklists methods for [ZLibraryApi].
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
  /// reports the total so the caller can fetch the rest via
  /// [getUserProfileBooklistsPage] (URL from
  /// [userProfileBooklistsPageUrl]). Page 1 of the paginated route is
  /// this same document.
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

  /// Create a booklist owned by the signed-in user. `POST
  /// /papi/booklist/create` with a JSON body `{title, description}`
  /// sent as `text/plain` (the same transport as postBookComment,
  /// so redirects are followed). Request shape taken from a browser
  /// capture on 2026-11-07 (Firefox, zh.z-library.sk), which showed no
  /// response data: the site answers with an empty body, so a 2xx
  /// with an empty body is success.
  ///
  /// A JSON answer is still handled leniently in case the site starts
  /// returning one: an explicit failure flag or an `error`/`message`
  /// field fails the call, otherwise it counts as created.
  /// [ApiResponse.data] is the new list when the JSON answer carries
  /// it (the site's form reads `response.readlist`), and null when the
  /// answer is an empty body — callers must not depend on it and
  /// should reload the "my booklists" page after a successful create
  /// when it is null.
  ///
  /// The site's form also sends the optional [color] (0–5), [isPrivate]
  /// and [bookId] ("create and add this book in one call", used by the
  /// add-to-booklist picker's inline create): they are included in the
  /// body only when given. The create answer is `{readlist: {id,
  /// title, hash, …}}` per the site's own form handler — see
  /// [_booklistFromCreateResponse].
  Future<ApiResponse<Booklist?>> createBooklist({
    required String title,
    String description = '',
    int? color,
    bool? isPrivate,
    int? bookId,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return ApiResponse.fail('booklist title is empty');
    }
    final body = <String, dynamic>{
      'title': cleanTitle,
      'description': description.trim(),
      if (color != null) 'color': color,
      if (isPrivate != null) 'private': isPrivate,
      if (bookId != null) 'bookId': bookId,
    };
    final raw = await _postText(
      '/papi/booklist/create',
      jsonEncode(body),
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      // The create call answers with an EMPTY body (confirmed by the
      // 2026-11-07 capture: no response data), so a 2xx with no body
      // is the success case. [_fromResponse] marks it with an
      // 'empty response' error and leaves [_Raw.body] null. Anything
      // else without JSON (a non-JSON page, a wall, a transport error,
      // a non-2xx status) is a failure and keeps its real cause.
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(null);
      }
      return ApiResponse.fail(
        raw.error ?? 'create booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'create booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(_booklistFromCreateResponse(json, cleanTitle));
  }

  /// Add a book to one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/add-book/{bookId}`, confirmed
  /// by a packet capture on 2026-11-09 (Firefox, zh.z-library.sk):
  /// HTTP 200 with `{"success": 1, "book": {"readlist_id": 4090055, "book_id": "18337950", "date": "2026-11-09T08:04:24.000000Z"}}`.
  /// No request body (GET). This endpoint only adds: the site calls
  /// [removeBookFromBooklist] when the filled bookmark in a list's
  /// submenu is clicked again — it is NOT a toggle.
  Future<ApiResponse<bool>> addBookToBooklist({
    required int booklistId,
    required int bookId,
  }) async {
    final response = await addBookToBooklistEntry(
      booklistId: booklistId,
      bookId: bookId,
    );
    if (!response.success) {
      return ApiResponse.fail(
        response.error ?? 'add to booklist failed',
        statusCode: response.statusCode,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Same call as [addBookToBooklist], but returns the readlist ENTRY
  /// id of the new membership row (what [removeBookFromBooklist]
  /// takes) instead of a bare success flag. The entry id is read from
  /// the response's `book` map as `readlist_id` first, else `id`:
  /// which field carries it is UNCONFIRMED — the 2026-11-09 capture
  /// showed `readlist_id`, the site's own picker reads `book.id`, so
  /// both are accepted. Null when the response carries neither (the
  /// add still succeeded; the caller can resolve the id later via
  /// [getReadlistBookId]).
  Future<ApiResponse<int?>> addBookToBooklistEntry({
    required int booklistId,
    required int bookId,
  }) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/$booklistId/add-book/$bookId',
    );
    if (raw.json == null) {
      return ApiResponse.fail(
        raw.error ?? 'add to booklist failed',
        statusCode: raw.status,
      );
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'add to booklist failed',
        ),
        statusCode: raw.status,
      );
    }
    final book = json['book'];
    final entryId = book is Map<String, dynamic>
        ? _asInt(book['readlist_id'] ?? book['id'])
        : null;
    return ApiResponse.ok(entryId);
  }

  /// All of the signed-in user's booklists plus whether [bookId] is in
  /// each: `GET /papi/booklist/current-user/{bookId}`, the same call
  /// [getReadlistBookId] uses for one list. The site's add-to-booklist
  /// picker renders this whole table (member flags, local search,
  /// inline create). Returns the entries in the server's order.
  Future<ApiResponse<List<BooklistMembership>>> getBooklistsForBook(
    int bookId,
  ) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/current-user/$bookId',
    );
    final json = raw.json;
    if (json == null) {
      return ApiResponse.fail(
        raw.error ?? 'get booklists failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'get booklists failed',
        ),
        statusCode: raw.status,
      );
    }
    final list = json['list'];
    if (list is! List) {
      return ApiResponse.fail(
        'get booklists failed',
        statusCode: raw.status,
      );
    }
    final memberships = <BooklistMembership>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final id = _asInt(entry['id']);
      if (id == null) continue;
      memberships.add(
        BooklistMembership(
          booklistId: id,
          title: entry['title']?.toString() ?? '',
          readlistBookId: _asInt(entry['readlistBookId']),
        ),
      );
    }
    return ApiResponse.ok(memberships);
  }

  /// Coerce an int-or-numeric-string JSON value, null otherwise.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Resolve the readlist ENTRY id for one (book, booklist) pair:
  /// `GET /papi/booklist/current-user/{bookId}`, confirmed by a
  /// packet capture on 2026-11-09 (Firefox, zh.z-library.sk): the
  /// detail page of 白鹿原 (book 11959979) loads this URL on page load
  /// and it answers `{"success": 1, "list": [...]}` with one entry
  /// per list the signed-in user owns. Each entry carries the list
  /// `id` plus `readlistBookId` — the per-(book, list) membership-row
  /// id, null when the book is not in that list (白鹿原 in 001:
  /// `readlistBookId` 161213534; in 嘎嘎嘎 and 555: null).
  ///
  /// Returns the entry id for the target list, or null when the book
  /// is not in that list (or the list is absent from the response).
  /// [removeBookFromBooklist] takes this entry id, NOT the book id —
  /// sending the book id there is what the server 500s on.
  Future<ApiResponse<int?>> getReadlistBookId({
    required int booklistId,
    required int bookId,
  }) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/current-user/$bookId',
    );
    final json = raw.json;
    if (json == null) {
      return ApiResponse.fail(
        raw.error ?? 'get booklist entry failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'get booklist entry failed',
        ),
        statusCode: raw.status,
      );
    }
    final list = json['list'];
    if (list is! List) {
      return ApiResponse.fail(
        'get booklist entry failed',
        statusCode: raw.status,
      );
    }
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      if (_asInt(entry['id']) != booklistId) continue;
      return ApiResponse.ok(_asInt(entry['readlistBookId']));
    }
    return ApiResponse.ok(null);
  }

  /// Remove a book from one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/remove-book/{readlistBookId}`,
  /// confirmed by a packet capture on 2026-11-09 (Firefox,
  /// zh.z-library.sk): list 4096101, entry 161286730, HTTP 200 with
  /// `{"success": 1}`. No request body (GET). This is a separate
  /// endpoint, NOT a toggle of [addBookToBooklist] — the site calls it
  /// when the filled bookmark in a list's submenu is clicked again.
  ///
  /// [readlistBookId] is the per-(book, list) membership-row id from
  /// [getReadlistBookId], NOT the book id: the website's own remove
  /// for 嘎嘎嘎 sent 161286730 while the removed book's id is in the
  /// 5–21M range, and 白鹿原 (book 11959979) in 001 carries
  /// `readlistBookId` 161213534. Sending the book id here is what the
  /// server answers with a generic 500 for every app remove, while
  /// the website remove succeeds.
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/$booklistId/remove-book/$readlistBookId',
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      // Same precedent as [deleteBooklist]: a final 2xx with an empty
      // body counts as removed; anything else without JSON (a wall, a
      // transport error, a non-2xx status) is a failure.
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(
        raw.error ?? 'remove from booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'remove from booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Delete one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/delete`, confirmed by a packet
  /// capture on 2026-11-09 (Firefox, zh.z-library.sk). The first
  /// response is 307 to the same URL with a `__diamwall` set-cookie
  /// (the DDoS-Guard challenge, not delete logic); the list was gone
  /// from the profile BOOKLISTS tab afterwards, so the delete itself
  /// succeeded. The final response body after following the redirect
  /// was never observed, so a non-JSON 2xx final response counts as
  /// success only when it is an empty body (same precedent as
  /// [createBooklist]) — an HTML final page fails instead.
  Future<ApiResponse<bool>> deleteBooklist(int booklistId) async {
    final raw = await _getWithRedirects('/papi/booklist/$booklistId/delete');
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(
        raw.error ?? 'delete booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'delete booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Edit one of the signed-in user's booklists: `POST
  /// /papi/booklist/{id}/edit` with `{title, description, private,
  /// color}` (the site's `#readlistForm` in edit mode). The answer
  /// carries the updated list as `{readlist: {...}}` — parsed the same
  /// way as a create answer. [ApiResponse.data] is the updated list,
  /// or null when the answer was an empty body (same lenient read as
  /// [createBooklist]).
  Future<ApiResponse<Booklist?>> editBooklist({
    required int id,
    required String title,
    String description = '',
    bool isPrivate = false,
    int? color,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return ApiResponse.fail('booklist title is empty');
    }
    final body = <String, dynamic>{
      'title': cleanTitle,
      'description': description.trim(),
      'private': isPrivate,
      if (color != null) 'color': color,
    };
    final raw = await _postText(
      '/papi/booklist/$id/edit',
      jsonEncode(body),
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(null);
      }
      return ApiResponse.fail(
        raw.error ?? 'edit booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'edit booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(_booklistFromCreateResponse(json, cleanTitle));
  }

  /// Change one of the signed-in user's booklists' color: `GET
  /// /papi/booklist/{id}/color/{0..5}` (the site's "…" menu, color
  /// submenu). No request body; a 2xx (JSON success or empty body)
  /// counts as changed.
  Future<ApiResponse<bool>> setBooklistColor({
    required int id,
    required int color,
  }) async {
    final raw = await _getWithRedirects('/papi/booklist/$id/color/$color');
    return _boolFromWriteRaw(raw, 'change booklist color failed');
  }

  /// Flip one of the signed-in user's booklists between public and
  /// private: `GET /papi/booklist/{id}/public` (the site's "…" menu).
  /// No parameters — the server flips the current state. No request
  /// body; a 2xx (JSON success or empty body) counts as flipped. The
  /// new state is NOT in the response; callers reload or flip their
  /// local flag on success.
  Future<ApiResponse<bool>> toggleBooklistPublic(int id) async {
    final raw = await _getWithRedirects('/papi/booklist/$id/public');
    return _boolFromWriteRaw(raw, 'change booklist visibility failed');
  }

  /// Favorite a booklist (anyone's): `POST
  /// /papi/booklist/{id}/favorite/add` (the heart on the site's list
  /// card). The site sends no body; `'{}'` is posted to keep the
  /// JSON-string transport. A 2xx (JSON success or empty body) counts
  /// as favorited.
  Future<ApiResponse<bool>> favoriteBooklist(int id) async {
    final raw = await _postText('/papi/booklist/$id/favorite/add', '{}');
    return _boolFromWriteRaw(raw, 'favorite booklist failed');
  }

  /// Unfavorite a booklist: `DELETE
  /// /papi/booklist/{id}/favorite/remove` (the filled heart on the
  /// site's list card). No request body; a 2xx (JSON success or empty
  /// body) counts as unfavorited.
  Future<ApiResponse<bool>> unfavoriteBooklist(int id) async {
    final raw = await _delete('/papi/booklist/$id/favorite/remove');
    return _boolFromWriteRaw(raw, 'unfavorite booklist failed');
  }

  /// Save the per-book note inside one of the signed-in user's
  /// booklists: `POST /papi/booklist/{id}/save-description/{entryId}`
  /// with `{bookDescription}`. The site sends a single space for an
  /// empty note, so an empty [description] is sent as `' '` here too.
  /// [entryId] is the readlist membership-row id (the card's
  /// `booklistsindex`, see [Book.readlistBookId]), NOT the book id.
  Future<ApiResponse<bool>> saveBookDescription({
    required int listId,
    required int entryId,
    required String description,
  }) async {
    final raw = await _postText(
      '/papi/booklist/$listId/save-description/$entryId',
      jsonEncode({
        'bookDescription': description.isEmpty ? ' ' : description,
      }),
    );
    return _boolFromWriteRaw(raw, 'save book note failed');
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

  /// Shared success read for the small write endpoints (color, public,
  /// favorite, save-description): a JSON `success: 1` wins; a final
  /// 2xx with an empty body counts as success (same precedent as
  /// [deleteBooklist]); anything else fails with its real cause.
  ApiResponse<bool> _boolFromWriteRaw(_Raw raw, String fallbackError) {
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(raw.error ?? fallbackError, statusCode: status);
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          fallbackError,
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Best-effort read of the list a create call returned. The site's
  /// form reads `response.readlist`, so that wrapper is tried first;
  /// the other wrappers are kept for a response shape that has not
  /// been seen yet. Needs a numeric `id` to count as a list. Returns
  /// null when nothing matches.
  Booklist? _booklistFromCreateResponse(
    Map<String, dynamic> json,
    String title,
  ) {
    for (final candidate in [
      json['readlist'],
      json['booklist'],
      json['list'],
      json['data'],
      json,
    ]) {
      if (candidate is! Map<String, dynamic>) continue;
      final id = candidate['id']?.toString() ?? '';
      if (!RegExp(r'^\d+$').hasMatch(id)) continue;
      final name = candidate['title']?.toString() ??
          candidate['topic']?.toString() ??
          title;
      return Booklist(
        id: id,
        name: name,
        description: candidate['description']?.toString() ?? '',
        count: 0,
        url: '$_base/booklist/$id',
      );
    }
    return null;
  }
}
