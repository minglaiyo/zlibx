import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for one book detail page: the payload
/// ([BookDetailExtras] — metadata rows, keywords and the related-
/// booklists block) the detail screen merges onto the eapi book.
///
/// The page is an HTML route behind the DiamWall, so fetching runs in
/// two stages, like every other HTML route (booklists / full-text /
/// categories):
///
/// 1. The plugin's [ZLibraryApi.fetchBookDetailExtras] over Dio — it
///    follows the wall's cookie hop (`307 + __diamwall`) itself.
/// 2. When that answers a browser-check challenge (`513`/`503` JS
///    wall — a bare Dio client can never pass it, live-verified
///    2026-11-12), the page URL is re-fetched through the WebView
///    solver, which runs the site's own challenge JS and returns the
///    real document. The solved page is parsed with the same plugin
///    parsers, so both stages yield identical data.
///
/// A solver run is only ever triggered on a challenge-shaped failure
/// (`isChallengeError`), never on a plain 404 / network error — a
/// dead book must not pop a WebView.
class BookDetailPageRepository {
  BookDetailPageRepository(this._api);

  final ZLibraryApi _api;

  /// One detail-page payload. `userId` / `userKey` are the signed-in
  /// session for the solver stage (the page is public; the session
  /// only personalises it), passed through from the caller's
  /// [UserProfileArgs]-style session pair.
  ///
  /// [allowVisibleSolver] / [solverTimeout] steer the challenge stage.
  /// The default keeps the interactive contract (headless solve, then a
  /// visible challenge page the user can clear). A caller that fetches
  /// this page as decoration — the detail screen's metadata rows load
  /// beside the already-painted body, see `bookDetailExtrasProvider` —
  /// must not have a full-screen WebView pushed over the page it is
  /// reading seconds later: pass `allowVisibleSolver: false` with a
  /// short [solverTimeout] and let the caller fall back to the cached
  /// (or missing) fields.
  Future<ApiResponse<BookDetailExtras>> fetch({
    required String href,
    String? userId,
    String? userKey,
    bool allowVisibleSolver = true,
    Duration? solverTimeout,
  }) async {
    final first = await _api.fetchBookDetailExtras(href);
    if (first.success) return first;
    if (!isChallengeError(first.error)) return first;
    // The wall escalated to the JS challenge: re-fetch the page
    // through the WebView solver (which executes that JS) and parse
    // the solved document.
    final url = pageUrl(href);
    final html = await fetchViaSolver(
      url,
      userId: userId,
      userKey: userKey,
      allowVisibleSolver: allowVisibleSolver,
      timeout: solverTimeout,
    );
    if (html == null) return first;
    final parsed = await parsePage(html, baseUrl: Uri.parse(url).origin);
    if (parsed == null) return first;
    return ApiResponse.ok(parsed);
  }

  /// The absolute detail-page URL for one site-relative [href] — the
  /// solver fallback's URL (the WebView follows it with the session
  /// cookies installed). Search/eapi responses carry the ABSOLUTE
  /// form (`https://<host>/book/…`, device-verified 2026-11-19), so
  /// an already-absolute href passes through — naive concatenation
  /// used to yield `https://<host>https://…` and the solve died on
  /// DNS.
  String pageUrl(String href) =>
      href.startsWith('http') ? href : 'https://${_api.domain}$href';

  /// The plugin's short error for a browser-check wall (plus the
  /// older shapes a wall can surface as) — same matcher as the other
  /// HTML routes.
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a detail payload, or null when
  /// it fails to parse — a parse failure must not escape the load and
  /// leave the detail screen stuck; treat a broken page like a fetch
  /// failure. A page with no `bookDetailsBox` is not a book page at
  /// all (the solver most likely landed on the wall or an error
  /// page) — also null.
  /// Async since phase 3: with the host's `bookDetailParseOverride`
  /// injected, the parse runs through the Rust bridge (a Future); the
  /// Dart implementation stays as the synchronous fallback.
  Future<BookDetailExtras?> parsePage(
    String html, {
    required String baseUrl,
  }) async {
    if (!html.contains('bookDetailsBox')) return null;
    try {
      final metadata = bookDetailParseOverride != null
          ? await bookDetailParseOverride!(html)
          : parseBookDetailProperties(html);
      // 与 Dio 路径 (fetchBookDetailExtras) 对齐：关键词与关联书单
      // 同样从文档里解析，两条路径产出同一份数据。
      return BookDetailExtras(
        metadata: metadata,
        keywords: parseBookDetailKeywords(html),
        relatedBooklists: parseRelatedBooklists(html, baseUrl: baseUrl),
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into
  /// the WebView's CookieManager first. Same contract as
  /// [FulltextRepository.fetchViaSolver]: the solved page is NOT
  /// stored in any cache.
  ///
  /// [allowVisibleSolver] false (plus [timeout], which bounds the
  /// headless solve itself) keeps the whole solve invisible: used by
  /// [BookDetailPageRepository.fetch] for the detail screen's
  /// decoration-only metadata, where popping a challenge page over a
  /// book the user is already reading is worse than losing the rating
  /// rows.
  Future<String?> fetchViaSolver(
    String url, {
    String? userId,
    String? userKey,
    bool allowVisibleSolver = true,
    Duration? timeout,
  }) async {
    final hasSession = userId != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await installSessionCookies(
        userId: userId,
        userKey: userKey,
        pageUrl: url,
      );
    }
    try {
      final html = allowVisibleSolver
          ? await WebviewChallengeSolver.fetchHtmlAfterChallenge(
              url,
              timeout: timeout,
            )
          : await WebviewChallengeSolver.fetchHtmlHeadlessOnly(
              url,
              timeout: timeout,
            );
      if (html == null ||
          html.isEmpty ||
          BooklistSolver.isChallengeHtml(html)) {
        return null;
      }
      await bridgeWallCookies(_api, url);
      return html;
    } finally {
      // O8: the session only lives for this solve (see BooklistSolver).
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }
}
