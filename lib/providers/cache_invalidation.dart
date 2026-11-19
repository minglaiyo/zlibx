import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'booklists_provider.dart';
import 'books_provider.dart';
import 'feed_controller.dart';


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
  // 详情页附加字段自 2026-11-15 起是独立的 provider（正文不再携带
  // 它），账号切换时要一起丢掉——旧会话解出来的那一页不能留给下一个
  // 账号。
  ref.invalidate(bookDetailExtrasProvider);
  ref.invalidate(randomBooksProvider);
  ref.invalidate(recommendedBooksProvider);
  // 信息流控制器（2026-11-20）：随机批与个性化推荐按账号取数，换号
  // 必须整体重建；热门/最新虽是全站内容，重走一遍首屏让启动缓存的
  // 旗标归位，代价可忽略。
  ref.invalidate(popularFeedProvider);
  ref.invalidate(recentFeedProvider);
  ref.invalidate(homeFeedProvider);
  ref.invalidate(downloadedBooksProvider);
  ref.invalidate(savedBooksProvider);
  // The booklists screen's own-lists tab is account-scoped too (the
  // same URL serves another account's lists after a switch, and the
  // controller does not watch authProvider): without this, switching
  // accounts leaves the previous account's lists on screen until a
  // manual refresh. Invalidating the autoDispose controller reloads
  // it under the new account (its build() kicks off loadFirst).
  ref.invalidate(booklistsControllerProvider);
  // Family providers must be invalidated as a whole (no member arg):
  // each cached (bookId -> bool / cover) entry belongs to the old
  // account's storage.
  ref.invalidate(isBookFavoritedProvider);
  ref.invalidate(historyCoverProvider);
}
