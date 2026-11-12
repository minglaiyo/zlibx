import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'books_provider.dart';

/// Invalidate every provider that caches account-scoped data.
///
/// This used to be a six-line `ref.invalidate(...)` block hand-copied
/// into logout / switchAccount / domain-switch — and the copies had
/// already drifted: none of them cleared the per-book favorites family
/// or the download-history cover map, so after switching accounts the
/// detail page showed the previous account's cached hearts and covers.
/// Keep the list here so it can never drift again.
void invalidateAccountScopedProviders(Ref ref) {
  ref.invalidate(bookDetailsProvider);
  ref.invalidate(recommendedBooksProvider);
  ref.invalidate(mostPopularBooksProvider);
  ref.invalidate(recentBooksProvider);
  ref.invalidate(downloadedBooksProvider);
  ref.invalidate(savedBooksProvider);
  // Family providers must be invalidated as a whole (no member arg):
  // each cached (bookId -> bool / cover) entry belongs to the old
  // account's storage.
  ref.invalidate(isBookFavoritedProvider);
  ref.invalidate(historyCoverProvider);
}
