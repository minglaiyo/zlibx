// Category browsing domain of [ZLibraryApi]: books on one category
// page, plus in-category search. A category page (`/category/{id}`,
// e.g. `/category/75`) is server-rendered HTML — parsed by
// [parseCategoryBooksPage] (see `category.dart`), NOT by the booklist
// detail parser: the category page's cards carry the per-card
// `deleted`/`favorite` flags and the page's `pagerOptions` page
// count, which the booklist parser drops. Split out as a mixin in
// the same library, `on ZLibraryApiBase`, so it can use the base
// class's private HTTP helpers directly.
part of 'zlibrary_api.dart';

/// Category browsing and in-category search methods for
/// [ZLibraryApi].
///
/// The site has no JSON endpoint for categories: the data source is
/// the HTML of `/category/{id}` (browse) and
/// `/category/{id}/{slug}/s/` (search, from the page's own search
/// form). A bare `/category/{id}` URL 301/302s to its slugged form,
/// so the fetch goes through [_getWithRedirects] and the slugged
/// form is never hand-built. The slug for a search URL comes from
/// the category tree's href when the caller has it; when it does not,
/// the bare id is used and the server redirects.
///
/// Multi-value filters (`languages`, `extensions`,
/// `selected_content_types`) are passed as BARE keys with a List
/// value: the requests set `ListFormat.multiCompatible` explicitly
/// (Dio 5.9.2's default is `multi`, bare repeated keys), which emits
/// the repeated `languages[]=x` form the site's form submits. Never
/// pass the `languages[]` key with that format — it would emit
/// `languages[][]`.
mixin ZLibraryCategories on ZLibraryApiBase {
  /// Books on one page of a category, plus the page count when the
  /// page carries it ([CategoryPage.totalPages] is null otherwise —
  /// never invented). Page 2+ is the same URL with `?page=N`.
  ///
  /// [order] is one of the category sort values
  /// (`popular`/`bestmatch`/`date`/`titleA`/`title`/`year`/
  /// `filesize`/`filesizeA`); null keeps the site's default.
  ///
  /// The category page is an HTML route, so like the booklist pages
  /// it can answer with the browser-check wall: a challenge page is
  /// reported as `HTTP 503: browser check page` (via
  /// [_looksLikeChallengePage]) so the caller can fall back to the
  /// WebView solver, exactly like the booklists screen does.
  Future<ApiResponse<CategoryPage>> getCategoryBooks(
    int categoryId, {
    int page = 1,
    String? order,
  }) {
    return _fetchCategoryPage(
      _categoryPath(categoryId),
      queryParameters: _categoryQuery(page: page, order: order),
    );
  }

  /// Search inside one category: `GET /category/{id}/{slug}/s/`.
  ///
  /// [query] is capped at 200 characters (the form's `maxlength`);
  /// an empty query fails without a request. [exact] sends `e=1`.
  /// No token is involved (unlike full-text search).
  Future<ApiResponse<CategoryPage>> searchInCategory({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
  }) {
    final q = query.length > 200 ? query.substring(0, 200) : query;
    if (q.trim().isEmpty) {
      return Future.value(ApiResponse.fail('empty query'));
    }
    return _fetchCategoryPage(
      _categoryPath(categoryId, slug: slug, search: true),
      queryParameters: _categoryQuery(
        page: page,
        order: order,
        query: q,
        exact: exact,
        yearFrom: yearFrom,
        yearTo: yearTo,
        languages: languages,
        extensions: extensions,
        contentTypes: contentTypes,
      ),
    );
  }

  /// The full URL of one category page — the string the app's screens
  /// use for their solver fallback (the WebView follows the bare-id
  /// redirect itself).
  String categoryPageUrl(int categoryId, {int page = 1, String? order}) {
    final query = _categoryQuery(page: page, order: order);
    return '$_base${_categoryPath(categoryId)}${_encodeQuery(query)}';
  }

  /// The full URL of an in-category search page, for the same
  /// callers. Same construction as [searchInCategory].
  String categorySearchUrl({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
  }) {
    final q = query.length > 200 ? query.substring(0, 200) : query;
    final params = _categoryQuery(
      page: page,
      order: order,
      query: q,
      exact: exact,
      yearFrom: yearFrom,
      yearTo: yearTo,
      languages: languages,
      extensions: extensions,
      contentTypes: contentTypes,
    );
    return '$_base${_categoryPath(categoryId, slug: slug, search: true)}'
        '${_encodeQuery(params)}';
  }

  Future<ApiResponse<CategoryPage>> _fetchCategoryPage(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final raw = await _getWithRedirects(
      path,
      extraHeaders: const {'Accept': 'text/html'},
      queryParameters: queryParameters,
    );
    final status = raw.status;
    if (status == null || status < 200 || status >= 300) {
      // A 503/513 is the mirror's browser-check wall even when the page
      // body carries none of _looksLikeChallengePage's markers (or is
      // empty): _fromError then answers a bare 'HTTP 503' that
      // isChallengeError would not match, so the solver fallback would
      // never trigger. Same status check as the download-history and
      // detail-extras paths. (Diagnosed 2026-11-12: the in-category
      // search 503'd twice while browse and eapi search worked.)
      if (status == 503 || status == 513) {
        _noteCategoryFetch(status, null, 0, challenge: true);
        return ApiResponse.fail(
          'HTTP $status: browser check page',
          statusCode: status,
        );
      }
      final errorLower = (raw.error ?? '').toLowerCase();
      final challenge = errorLower.contains('browser check') ||
          errorLower.contains('cf_blocked');
      _noteCategoryFetch(status, null, 0, challenge: challenge);
      return ApiResponse.fail(
        raw.error ?? 'category failed (HTTP $status)',
        statusCode: status,
      );
    }
    final html = raw.body;
    if (html == null || html.isEmpty) {
      _noteCategoryFetch(status, html, 0);
      return ApiResponse.fail(
        raw.error ?? 'category failed',
        statusCode: status,
      );
    }
    if (ZLibraryApiBase._looksLikeChallengePage(html)) {
      _noteCategoryFetch(status, html, 0, challenge: true);
      return ApiResponse.fail(
        'HTTP $status: browser check page',
        statusCode: status,
      );
    }
    final parsed = parseCategoryBooksPage(html, baseUrl: _base);
    _noteCategoryFetch(status, html, parsed.books.length);
    return ApiResponse.ok(parsed);
  }

  /// Temporary diagnostic (category search, 2026-11-12): summarize what
  /// a category page fetch actually returned, so the app can log it.
  /// Release-safe: HTTP status, whether the error is a challenge error,
  /// page title and element counts only — never a query, URL, cookie or
  /// body preview. Remove with the diagnostic.
  void _noteCategoryFetch(
    int? status,
    String? html,
    int parsed, {
    bool challenge = false,
  }) {
    if (html == null || html.isEmpty) {
      ZLibraryApiBase.lastCategoryFetchDebug =
          'status=$status challenge=$challenge html=empty parsed=$parsed';
      return;
    }
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    var title = titleMatch?.group(1) ?? '';
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.length > 60) title = '${title.substring(0, 60)}…';
    final hasBox = html.contains('searchResultBox');
    final rawCards = '<z-bookcard'.allMatches(html).length;
    ZLibraryApiBase.lastCategoryFetchDebug =
        'status=$status challenge=$challenge title=$title hasBox=$hasBox rawCards=$rawCards parsed=$parsed';
  }

  /// `/category/{id}`, `/category/{id}/{slug}`, or
  /// `/category/{id}/{slug}/s/` (search). The slug is used only when
  /// the caller passes one from the tree href; the bare id is always
  /// valid (the server redirects to the slugged form).
  String _categoryPath(
    int categoryId, {
    String? slug,
    bool search = false,
  }) {
    final slugged = slug == null || slug.isEmpty ? '' : '/$slug';
    return '/category/$categoryId$slugged${search ? '/s/' : ''}';
  }

  /// The query map for a category browse/search request. List values
  /// stay lists under bare keys (see the mixin doc comment); empty
  /// lists are dropped so the site sees no filter at all.
  Map<String, dynamic> _categoryQuery({
    required int page,
    String? order,
    String? query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
  }) {
    return {
      if (query != null) 'q': query,
      if (exact) 'e': '1',
      if (yearFrom != null) 'yearFrom': '$yearFrom',
      if (yearTo != null) 'yearTo': '$yearTo',
      if (languages != null && languages.isNotEmpty)
        'languages': languages,
      if (extensions != null && extensions.isNotEmpty)
        'extensions': extensions,
      if (contentTypes != null && contentTypes.isNotEmpty)
        'selected_content_types': contentTypes,
      if (order != null) 'order': order,
      'page': '$page',
    };
  }

  /// Encode a query map the way `ListFormat.multiCompatible` does:
  /// scalars as `key=value`, lists as repeated `key[]=value`. Used
  /// only for the absolute solver URLs
  /// ([categoryPageUrl]/[categorySearchUrl]); the Dio fetches pass
  /// the map itself and let Dio encode it.
  String _encodeQuery(Map<String, dynamic> query) {
    final parts = <String>[];
    for (final entry in query.entries) {
      final key = Uri.encodeQueryComponent(entry.key);
      final value = entry.value;
      if (value is List) {
        for (final item in value) {
          parts.add('$key[]=${Uri.encodeComponent(item.toString())}');
        }
      } else {
        parts.add('$key=${Uri.encodeComponent(value.toString())}');
      }
    }
    return parts.isEmpty ? '' : '?${parts.join('&')}';
  }
}
