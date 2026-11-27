/// Hive box / settings key names owned by StorageService.
///
/// P1-4 split of `storage_service.dart`: the key names live in exactly
/// one place so the per-domain repositories and the settings→library
/// migration all use the same strings. The values are unchanged from
/// the original file — renaming a key would orphan existing on-device
/// data, so treat every string here as frozen.

// Legacy shared favorites key: every account read and wrote the
// same list. Kept only so the one-time migration can find it — no
// favorites read/write uses it anymore (see [favoritesKeyFor]).
const String kFavoritesKey = 'favorite_books';

// _keyDownloads was removed with the dead saveDownloadedBook() method:
// it stored `bookInfo.toString()` (a Dart debug string, not JSON, not
// parseable) and had no callers — download history lives in
// [kDownloadHistoryKey] below.
const String kThemeModeKey = 'theme_mode';
const String kDownloadPathKey = 'download_path';
const String kDownloadHistoryKey = 'download_history';

/// Per-account server download-history cache key:
/// `server_download_history_<accountId>`. Deliberately NOT
/// [kDownloadHistoryKey] above — that key is the LOCAL file-download
/// map ({bookId: {title, author, filePath, ...}}), a different thing.
/// Same account-scoping rule as [favoritesKeyFor]: the account id is
/// the Z-Library user id, so each account reads only its own cached
/// history and a different account starts with no cache.
const String kServerDownloadHistoryKey = 'server_download_history';

/// Per-account server download-history cache key (see above).
String serverDownloadHistoryKeyFor(String accountId) =>
    '${kServerDownloadHistoryKey}_$accountId';

/// Per-account favorites key: `favorite_books_<accountId>`.
/// The account id is the Z-Library user id (a String — see User.id),
/// the same value stored as the `remix_userid` credential, so the
/// key follows the signed-in account and never a display name or
/// email. Each account reads and writes only its own key, which is
/// what keeps the local hearts in sync with the account-scoped
/// server list after a switch.
String favoritesKeyFor(String accountId) => '${kFavoritesKey}_$accountId';

/// 下载历史逐条键（审查 A2，2026-11-20）：每本书一个 `dl:<bookId>`
/// 键，值就是条目 Map（hive 原生存储，不再整表 JSON 编解码）；
/// `dl_order` 保插入序（重加已存在的 id 保持原位——与旧整表 Map 的
/// 语义一致）。增删 O(1)，一条坏数据只丢自己。
const String kDlPrefix = 'dl:';
const String kDlOrderKey = 'dl_order';

/// One global JSON blob (`downloaded_book_metadata`) in the settings
/// box — deliberately NOT account-scoped, unlike the history cache
/// above: which account downloaded a book does not change its author
/// or cover.
const String kDownloadedBookMetadataKey = 'downloaded_book_metadata';

/// 上限：blob 是整读整写，条目无时间戳，超过上限丢先写入的（插入
/// 序 = Dart Map 的保留序）。一万条 × ~150B 也才 ~1.5MB，正常用户
/// 触不到；上限只防长期膨胀。
const int kDownloadedBookMetadataCap = 5000;

/// Book-detail extras cache blob key (library box) + entry cap.
const String kBookDetailExtrasKey = 'book_detail_extras';
const int kBookDetailExtrasCap = 2000;

/// 详情正文缓存前缀（library 盒）。值 = Book.toJson() + fetchedAt。
const String kBookDetailCachePrefix = 'bookdetail:';

/// 详情正文 7 天 TTL：eapi 的简介/出版社/评分几天内不变，staleness
/// 换"重开同一本零请求秒开"（惯例同 book_detail_extras 的 7 天）。
const Duration kBookDetailCacheTtl = Duration(days: 7);

/// 短 hash → eapi 真 hash 的解析缓存前缀。eapi 的 hash 是书目的规
/// 范标识，bookId 不变就不变——不设 TTL，写坏也有自愈（取缓存的
/// hash 若被服务端拒，vendor 照旧走解析重试，app 拿到新解析覆盖回
/// 去）。
const String kEapiHashResolvePrefix = 'eapihash:';

/// 迁移完成标志键（留在 settings：它本身就是偏好级的小键）。
const String kLibraryMigratedFlag = 'library_migrated_v1';
