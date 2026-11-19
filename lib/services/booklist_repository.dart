import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_html_cache.dart';
import 'booklist_solver.dart';
import 'external_logger.dart';


/// Data layer for the booklist screens: fetching (fast Dio first, the
/// WebView solver on the browser-check wall), parsing, the persistent
/// [BooklistHtmlCache] and invalidation all live here. The Riverpod
/// controllers keep only their state machines (the generation / alive
/// guards and the loading flags) and apply what this repository
/// returns to their state.
///
/// The repository holds no state of its own: every method is a
/// stateless operation on the [ZLibraryApi] it was constructed with or
/// on the cache, so a controller can keep its generation checks around
/// each call exactly where they were. In particular a fetch is never
/// persisted here before the controller has decided the load is still
/// current and not invalidated (see
/// [BooklistHtmlCache.wasInvalidatedAfter]) — the controller calls
/// [storeBooksPage] at exactly the point where the store used to
/// happen.
class BooklistRepository {
  BooklistRepository(this._api);

  final ZLibraryApi _api;

  final AppLogger _logger = AppLogger();

  // ---- cache reads ----

  /// Cached books of one detail JSON page (`#json-page=N`), or null
  /// when never cached, stale or corrupt.
  /// Synchronous buffer hit (fresh same-process stores); null means
  /// "ask the async path". See [BooklistHtmlCache.peekBooksPage].
  List<Book>? peekBooksPage(String url, int page, {String? accountId}) =>
      BooklistHtmlCache.peekBooksPage(url, page, accountId: accountId);

  String? peekDetailHtml(String url, {String? accountId}) {
    final html = BooklistHtmlCache.peekHtml(url, accountId: accountId);
    if (html == null || BooklistSolver.isChallengeHtml(html)) return null;
    return html;
  }

  Future<List<Book>?> cachedBooksPage(
    String url,
    int page, {
    String? accountId,
  }) => BooklistHtmlCache.getBooksPage(url, page, accountId: accountId);

  /// The cached raw detail HTML when it is usable — present and not a
  /// challenge page — else null. A stored challenge page must never be
  /// parsed as an (empty) first page.
  Future<String?> cachedDetailHtml(String url, {String? accountId}) async {
    final cachedHtml = await BooklistHtmlCache.get(url, accountId: accountId);
    return (cachedHtml != null && !BooklistSolver.isChallengeHtml(cachedHtml))
        ? cachedHtml
        : null;
  }

  /// Parses a cached detail page's HTML into first-page books, or null
  /// when the cached page fails to parse. The cache was written by an
  /// older app run: a parse failure there must not escape the load
  /// (which runs from a microtask) and leave the screen loading
  /// forever — treat a broken cache like a cache miss. Async since
  /// phase 3: the parse routes through the Rust bridge when injected.
  Future<List<Book>?> parseCachedDetailBooks(
    String html, {
    required String baseUrl,
  }) async {
    try {
      return await parseBooklistDetailBooksH(html, baseUrl: baseUrl);
    } catch (_) {
      return null;
    }
  }

  /// The cached own/discover list page parsed into its model, or null
  /// when nothing usable is cached. The cached HTML is user-unreachable
  /// data from an older app run: a parse failure there must not leave
  /// the screen loading forever, so a broken cache is treated like a
  /// cache miss and the caller falls through to the network path.
  /// Async since phase 3 (Rust bridge when injected).
  Future<BooklistsPage?> cachedListPage(String url, {String? accountId}) async {
    final cachedHtml = await BooklistHtmlCache.get(
      url,
      accountId: accountId,
    );
    if (cachedHtml == null || BooklistSolver.isChallengeHtml(cachedHtml)) {
      return null;
    }
    try {
      return await parseBooklistsPageH(
        cachedHtml,
        baseUrl: Uri.parse(url).origin,
      );
    } catch (e) {
      _logger.warning(
        'Cached booklists page failed to parse, ignoring it',
        tag: 'Booklists',
        error: e,
      );
      return null;
    }
  }

  // ---- parsing (fresh pages) ----

  /// Parses the detail page's HTML into first-page books. Unlike
  /// [parseCachedDetailBooks] this is the network path's parse: a
  /// failure propagates to the caller like any fetch error.
  /// Async since phase 3 (Rust bridge when injected).
  Future<List<Book>> parseDetailBooks(String html, {required String baseUrl}) =>
      parseBooklistDetailBooksH(html, baseUrl: baseUrl);

  /// Parses one own/discover list page's HTML into its model.
  /// Async since phase 3 (Rust bridge when injected).
  Future<BooklistsPage> parseListPage(String html, {required String baseUrl}) =>
      parseBooklistsPageH(html, baseUrl: baseUrl);

  // ---- cache writes / invalidation ----

  /// Persists one parsed detail page (page 1 is HTML; page 2+ is JSON)
  /// under [url]'s cache key. [fetchedAt] is when the fetch that
  /// produced this page started, so a page older than the URL's last
  /// invalidation is dropped instead of stored.
  void storeBooksPage(
    String url,
    int page,
    List<Book> books, {
    String? accountId,
    DateTime? fetchedAt,
  }) {
    BooklistHtmlCache.storeBooksPage(
      url,
      page,
      books,
      accountId: accountId,
      fetchedAt: fetchedAt,
    );
  }

  /// A "when did this fetch start" stamp for [wasInvalidatedAfter].
  /// Take it from here instead of [DateTime.now] — see
  /// [BooklistHtmlCache.stamp] for why the ordering needs the monotonic
  /// generator (a wall clock that only ticks every ~2 ms cannot tell a
  /// load started after a delete apart from one started before it, and
  /// the conservative reading drops a fresh page).
  DateTime stamp() => BooklistHtmlCache.stamp();

  /// True when a fetch that started at [fetchedAt] predates a write
  /// (add/remove a book) to this URL family: its data must not be
  /// applied to the visible list nor re-stored.
  bool wasInvalidatedAfter(
    String url,
    DateTime fetchedAt, {
    String? accountId,
  }) {
    return BooklistHtmlCache.wasInvalidatedAfter(
      url,
      fetchedAt,
      accountId: accountId,
    );
  }

  /// Drops every cached page of one booklist (the raw detail HTML plus
  /// all parsed JSON pages) and records the invalidation tombstone. Use
  /// after a successful write so the removed data cannot reappear from
  /// cache on the next open.
  void invalidateBooklist(String url, {String? accountId}) {
    BooklistHtmlCache.invalidateBooklist(url, accountId: accountId);
  }

  // ---- API: fast Dio path ----

  /// The detail page's own first page (the server-rendered document,
  /// parsed by the plugin).
  Future<ApiResponse<List<Book>>> fetchDetailBooks(Booklist list) =>
      _api.getBooklistDetailBooks(list);

  /// Detail JSON pages (2 and up; page 1 is server-rendered).
  Future<ApiResponse<BooklistBooksPage>> fetchBooksPage(
    String listId, {
    int page = 2,
  }) => _api.getBooklistBooks(listId, page: page);

  /// One page of the signed-in user's own booklists.
  Future<ApiResponse<BooklistsPage>> searchMyBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) => _api.searchMyBooklists(query: query, order: order, page: page);

  /// One page of the public booklists to discover.
  Future<ApiResponse<BooklistsPage>> searchPublicBooklists({
    String query = '',
    String order = 'popular',
    int page = 1,
  }) => _api.searchPublicBooklists(query: query, order: order, page: page);

  /// Creates a booklist owned by the signed-in user. [color] (0–5),
  /// [isPrivate] and [bookId] ("create and add this book in one call")
  /// are sent only when given.
  Future<ApiResponse<Booklist?>> createBooklist({
    required String title,
    String description = '',
    int? color,
    bool? isPrivate,
    int? bookId,
  }) => _api.createBooklist(
    title: title,
    description: description,
    color: color,
    isPrivate: isPrivate,
    bookId: bookId,
  );

  /// Edits one of the signed-in user's booklists (title, description,
  /// private flag, color). Returns the updated list when the answer
  /// carried it, else null (the caller then reloads).
  Future<ApiResponse<Booklist?>> editBooklist({
    required int id,
    required String title,
    String description = '',
    bool isPrivate = false,
    int? color,
  }) => _api.editBooklist(
    id: id,
    title: title,
    description: description,
    isPrivate: isPrivate,
    color: color,
  );

  /// Changes one of the signed-in user's booklists' color (0–5).
  Future<ApiResponse<bool>> setBooklistColor({
    required int id,
    required int color,
  }) => _api.setBooklistColor(id: id, color: color);

  /// Flips one of the signed-in user's booklists between public and
  /// private. The new state is not in the response; the caller flips
  /// its local flag on success.
  Future<ApiResponse<bool>> toggleBooklistPublic(int id) =>
      _api.toggleBooklistPublic(id);

  /// Favorites a booklist (anyone's).
  Future<ApiResponse<bool>> favoriteBooklist(int id) =>
      _api.favoriteBooklist(id);

  /// Unfavorites a booklist.
  Future<ApiResponse<bool>> unfavoriteBooklist(int id) =>
      _api.unfavoriteBooklist(id);

  /// Saves the per-book note inside one of the signed-in user's
  /// booklists. [entryId] is the readlist membership-row id, NOT the
  /// book id. An empty note is sent as a single space (the site's
  /// convention).
  Future<ApiResponse<bool>> saveBookDescription({
    required int listId,
    required int entryId,
    required String description,
  }) => _api.saveBookDescription(
    listId: listId,
    entryId: entryId,
    description: description,
  );

  /// All of the signed-in user's booklists plus whether [bookId] is in
  /// each one (the add-to-booklist picker's data source).
  Future<ApiResponse<List<BooklistMembership>>> getBooklistsForBook(
    int bookId,
  ) => _api.getBooklistsForBook(bookId);

  /// Adds a book to one of the signed-in user's booklists and returns
  /// the new membership-row id (or null when the response did not
  /// carry it — see [ZLibraryApi.addBookToBooklistEntry]).
  Future<ApiResponse<int?>> addBookToBooklistEntry({
    required int booklistId,
    required int bookId,
  }) => _api.addBookToBooklistEntry(booklistId: booklistId, bookId: bookId);

  /// Recommended booklists for the discover tab's recommendation slots.
  Future<ApiResponse<List<Booklist>>> getRecommendedBooklists({
    int booklistsCount = 10,
  }) => _api.getRecommendedBooklists(booklistsCount: booklistsCount);

  /// The full URL of one own/discover list page — also the cache key
  /// the list pages are stored under.
  String booklistsPageUrl({
    bool mine = true,
    String query = '',
    String? order,
    int page = 1,
  }) =>
      _api.booklistsPageUrl(mine: mine, query: query, order: order, page: page);

  /// The readlist ENTRY id of one (book, list) membership row — the id
  /// remove-book takes, never the book id (see
  /// [removeBookFromBooklist]).
  Future<ApiResponse<int?>> resolveBookEntry({
    required int booklistId,
    required int bookId,
  }) => _api.getReadlistBookId(booklistId: booklistId, bookId: bookId);

  /// Removes one membership row from a booklist. Takes the readlist
  /// ENTRY id from [resolveBookEntry], not the book id — sending the
  /// book id is what the server 500s on.
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) => _api.removeBookFromBooklist(
    booklistId: booklistId,
    readlistBookId: readlistBookId,
  );

  /// Deletes one of the user's own booklists.
  Future<ApiResponse<bool>> deleteBooklist(int booklistId) =>
      _api.deleteBooklist(booklistId);

  // ---- API: WebView solver fallback ----

  /// The plugin's short error for a browser-check wall (plus the older
  /// shapes a wall can surface as).
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into the
  /// WebView's CookieManager first (own-list pages need it). On success
  /// the page is stored in the cache under [accountId], so the next
  /// load skips the solver.
  Future<String?> fetchViaSolver(
    String url, {
    String? accountId,
    String? userId,
    String? userKey,
  }) => BooklistSolver.fetchHtml(
    _api,
    url,
    accountId: accountId,
    userId: userId,
    userKey: userKey,
  );
}
