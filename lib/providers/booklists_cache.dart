import '../services/booklist_repository.dart';
import 'booklists_state.dart';

/// Cache invalidation for the booklists pages (P1-4 split of
/// booklists_provider.dart).
///
/// The page cache itself lives in [BooklistRepository] /
/// `BooklistHtmlCache`; this class only owns the *keys* the controller
/// invalidates after a write (delete / create / edit / color /
/// visibility / favorite) so the next refresh cannot repaint the
/// pre-write page. The account partition comes from the controller
/// (`BooklistsController._accountIdFor` equivalent): the own-lists and
/// favorites tabs are account-scoped (the same URL serves another
/// account's lists after a switch); discover is public.
class BooklistsCache {
  BooklistsCache(this._repository, this._accountIdFor);

  final BooklistRepository _repository;

  /// Account partition for [tab]: null for the public discover tab,
  /// the signed-in account id (or 'signed-out') otherwise.
  final String? Function(BooklistTab tab) _accountIdFor;

  /// Invalidate one cached list page (a detail page or a list page
  /// URL). [accountId] overrides the tab partition when the write was
  /// scoped at capture time (edit / color / visibility).
  void invalidateBooklist(
    String url,
    BooklistTab tab, {
    String? accountId,
  }) {
    _repository.invalidateBooklist(
      url,
      accountId: accountId ?? _accountIdFor(tab),
    );
  }

  /// Invalidate the cached mine list page (the URL `loadFirst` reads
  /// and writes), so a later refresh fetches fresh instead of
  /// repainting the pre-write page.
  void invalidateMinePage({required String query, required String order}) {
    _repository.invalidateBooklist(
      _repository.booklistsPageUrl(
        mine: true,
        query: query,
        order: order,
        page: 1,
      ),
      accountId: _accountIdFor(BooklistTab.mine),
    );
  }

  /// Invalidate the cached favorites list page so the favorites tab
  /// refetches after a favorite/unfavorite. Best-effort on the query/
  /// order key: while the favorites tab itself is showing, the current
  /// query/order hit exactly; from any other tab the default page
  /// (empty search, the screen's own order) is invalidated, and a
  /// user-narrowed favorites page settles on its next SWR refresh.
  void invalidateFavoritePage({
    required bool onFavoriteTab,
    required String query,
    required String order,
  }) {
    _repository.invalidateBooklist(
      _repository.booklistsPageUrl(
        mine: false,
        favorite: true,
        query: onFavoriteTab ? query : '',
        order: onFavoriteTab ? order : 'popular',
        page: 1,
      ),
      accountId: _accountIdFor(BooklistTab.favorite),
    );
  }
}
