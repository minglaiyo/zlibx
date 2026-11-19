// Split out of `books_provider.dart` (M3): bookDetailsProvider + BookIdentifier (its parameter type).
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/book_detail_page_repository.dart';
import '../services/storage_service.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Book Details ────────────────────────────────────────────────────

/// 详情页附加信息（卷/ISBN/IPFS/评分）的新鲜窗口：卷/ISBN/IPFS 是
/// 版本常量，只有两个社区评分会变（兴趣分另有 eapi interestScore
/// 兜底）——7 天内的旧评分换取重复打开整段跳过几百 KB 的 HTML 下载
/// （TTL 惯例同 BooklistHtmlCache）。
const _bookDetailExtrasTtl = Duration(days: 7);

/// 附加信息这一条路的总预算（缓存未命中时的一次抓取，含可能的后台
/// 求解）。插件里 HTML 的 receiveTimeout 是 300 s——慢链路收完几百 KB
/// 确实可能要那么久，但那只是几行装饰字段，正文不该陪它等：过这个点
/// 就放弃本轮，用过期缓存兜底，下次打开再补。
const _bookDetailExtrasBudget = Duration(seconds: 25);

/// 后台求解的预算：比 [_bookDetailExtrasBudget] 小，好让求解自己先结
/// 束——外层 timeout 只是放弃等待，WebView 求解仍在背后跑完它自己那
/// 60 s。
const _bookDetailExtrasSolverTimeout = Duration(seconds: 15);

/// 详情页缓存键：详情页的 PATH（每版本稳定）。手动剥掉 query/
/// fragment，不走 Uri.parse——它会把这个未编码的中文路径百分号编
/// 码，同一个 href 的键就因写法不同而漂移（CI 2026-11-13：测试夹具
/// 的中文 slug 被编码成 %E5%90%88…，缓存全 miss）。
String bookDetailExtrasKey(String href) {
  final query = href.indexOf('?');
  final fragment = href.indexOf('#');
  var end = href.length;
  if (query >= 0 && query < end) end = query;
  if (fragment >= 0 && fragment < end) end = fragment;
  return href.substring(0, end);
}

bool _extrasFresh(Map<String, dynamic> extras) {
  final fetchedAt = extras['fetchedAt'];
  if (fetchedAt is! int) return false;
  // 格式标记：关联书单上线后写出的条目都带 `booklists` 键（可为空
  // 表）。上线前写入的旧条目没有它——按过期处理、重抓一次补齐，
  // 否则新特性会被 7 天 TTL 的旧缓存整周遮住（覆盖安装保留 Hive
  // 数据，装机当天就会踩中）。
  if (extras['booklists'] is! List) return false;
  return DateTime.now().millisecondsSinceEpoch - fetchedAt <
      _bookDetailExtrasTtl.inMilliseconds;
}

/// [BookDetailExtras] → 可持久化的 JSON（7 个 metadata 字段 + 关键词
/// 列表 + 关联书单最小卡片；fetchedAt 由 storage 层盖章）。
Map<String, dynamic> _extrasJsonOf(BookDetailExtras extras) {
  final json = <String, dynamic>{
    'volume': extras.metadata.volume,
    'isbn10': extras.metadata.isbn10,
    'isbn13': extras.metadata.isbn13,
    'ipfsCid': extras.metadata.ipfsCid,
    'ipfsCidBlake2b': extras.metadata.ipfsCidBlake2b,
    'ratingInterest': extras.metadata.ratingInterest,
    'ratingQuality': extras.metadata.ratingQuality,
    if (extras.keywords.isNotEmpty) 'keywords': extras.keywords,
    // 恒写（含空表）：键的存在即新格式标记，见 [_extrasFresh]。
    'booklists': [
      for (final list in extras.relatedBooklists) _relatedBooklistJson(list),
    ],
  };
  return json;
}

/// 关联书单卡片的持久化形态：只存展示与导航需要的字段（id/name/url/
/// cover/count）。previewBooks 不进缓存——点开书单页会自己拉正文，
/// 卡片列表本身不带它们也无损。
Map<String, dynamic> _relatedBooklistJson(Booklist list) => {
  'id': list.id,
  'name': list.name,
  'url': list.url,
  if (list.coverUrl.isNotEmpty) 'cover': list.coverUrl,
  if (list.count != null) 'count': list.count,
};

/// 缓存 JSON → 关联书单列表（[bookDetailExtrasProvider] 那条腿的
/// `booklists` 键）。逐条容错：坏条目跳过、键缺失给空——旧缓存没有
/// 这一键时就是空列表（下次 TTL 过期自然补上），绝不让详情页报错。
List<Booklist> bookDetailRelatedBooklists(Map<String, dynamic>? extras) {
  final raw = extras == null ? null : extras['booklists'];
  if (raw is! List) return const [];
  final lists = <Booklist>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final name = entry['name'];
    final url = entry['url'];
    if (id is! String || id.isEmpty) continue;
    if (name is! String || name.isEmpty) continue;
    if (url is! String || url.isEmpty) continue;
    final count = entry['count'];
    final cover = entry['cover'];
    lists.add(
      Booklist(
        id: id,
        name: name,
        url: url,
        coverUrl: cover is String ? cover : '',
        count: count is int ? count : int.tryParse('${count ?? ''}'),
      ),
    );
  }
  return lists;
}

/// 缓存 JSON → 合并进书本体。逐字段容错取值：缓存是手改/旧版本的
/// JSON 时最坏也只是丢字段，绝不让详情页报错。
String? _extrasString(Object? value) => value is String ? value : null;

/// 附加字段 JSON 并进书本体（[bookDetailsProvider] 的正文 +
/// [bookDetailExtrasProvider] 的装饰字段）。copyWith 的空值语义是
/// “保留原值”，所以附加字段只会补行、不会抹掉 eapi 已有的值。
List<String>? _extrasStringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : null;

Book applyBookDetailExtras(Book book, Map<String, dynamic> extras) =>
    book.copyWith(
      keywords: _extrasStringList(extras['keywords']),
      volume: _extrasString(extras['volume']),
      isbn10: _extrasString(extras['isbn10']),
      isbn13: _extrasString(extras['isbn13']),
      ipfsCid: _extrasString(extras['ipfsCid']),
      ipfsCidBlake2b: _extrasString(extras['ipfsCidBlake2b']),
      ratingInterest: _extrasString(extras['ratingInterest']),
      ratingQuality: _extrasString(extras['ratingQuality']),
    );

/// 详情页正文（eapi 的小 JSON：书名/作者/简介/文件信息）。
///
/// autoDispose：详情页关掉后无人 watch 即释放缓存。此前常驻内存，
/// 长会话逐本累积（每本详情是全量 [Book]）；相似书链路中每一页
/// 详情始终 watch 自己的 identifier，不会产生重复请求。
///
/// 只发 eapi 这一个请求，不等详情页 HTML——2026-11-15 拆分。
/// 此前（1.5.8 起）两者在同一个 Future 里 await：eapi 早到了也要等
/// 那几百 KB 的 HTML 页（最多 5 跳、receiveTimeout 300 s，命中
/// DiamWall 还要起 WebView 求解），正文跟着一起卡住——这就是
/// “详情页比以前的版本慢”的来源（1.5.7 及更早只有 eapi 一个
/// 请求）。附加字段改由 [bookDetailExtrasProvider] 独立加载，
/// 到达后由 [BookDetailScreen] 并进本文。
///
/// eapi 自己失败照旧抛出：正文没有兜底可退，页面显示错误 + 重试。
final bookDetailsProvider = FutureProvider.autoDispose
    .family<Book, BookIdentifier>((ref, identifier) async {
      final api = ref.watch(zlibraryApiProvider);
      final response = await api.getBookInfo(
        identifier.bookId,
        identifier.hashId,
        title: identifier.title,
      );
      if (!response.success) {
        throw StateError(response.error ?? 'Failed to load book details');
      }
      final book = response.data;
      if (book == null) {
        throw StateError('Book details response did not contain a book');
      }
      // 路由带的 href 优先（列表页给的那个）；eapi 自己的 href 也
      // 认，路由没带时附加字段靠它定位。
      final routeHref = identifier.href;
      return (routeHref == null || routeHref.isEmpty)
          ? book
          : book.copyWith(href: routeHref);
    });

/// 详情页 HTML 上的附加字段（卷/ISBN/IPFS/评分），按
/// [bookDetailExtrasKey] 缓存；并进本文见 [applyBookDetailExtras]。
///
/// 与正文彻底独立（互不等待）：
///  * 持久缓存新鲜 → 直接返回，零请求。
///  * 未命中/过期 → 抓一次并回写；整段只给
///    [_bookDetailExtrasBudget] 预算，命中墙时只允许后台求解
///    （[_bookDetailExtrasSolverTimeout]，不弹可见验证页）——用户
///    此刻在读的是正文，评分行缺着比被 WebView 盖一层强。
///  * 失败/超时 → 退回过期缓存（可能为 null），永不抛。
///
/// 返回 null 意思是“这一轮拿不到附加字段”，不是错误状态。
final bookDetailExtrasProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, href) async {
      final key = bookDetailExtrasKey(href);
      final storage = ref.watch(storageServiceProvider);
      final cached = storage.getBookDetailExtrasSync(key);
      if (cached != null && _extrasFresh(cached)) return cached;
      final api = ref.watch(zlibraryApiProvider);
      // 会话取快照（同旧行为）：登录态变化由
      // invalidateAccountScopedProviders 统一重跑，这里不自己转圈。
      final user = ref.read(authProvider).user;
      try {
        final result = await BookDetailPageRepository(api)
            .fetch(
              href: href,
              userId: user?.id,
              userKey: user?.remixUserkey,
              allowVisibleSolver: false,
              solverTimeout: _bookDetailExtrasSolverTimeout,
            )
            .timeout(_bookDetailExtrasBudget);
        if (result.success && result.data != null) {
          final json = _extrasJsonOf(result.data!);
          unawaited(storage.mergeBookDetailExtras(key, json));
          return json;
        }
        logIgnored(
          'book_details_metadata',
          StateError(result.error ?? 'book detail page failed'),
        );
      } on Object catch (error) {
        // 含 TimeoutException：慢链路/求解卡住时放弃这一轮。
        logIgnored('book_details_metadata', error);
      }
      return cached;
    });

class BookIdentifier {
  final String bookId;
  final String hashId;

  /// Book title, used only to resolve the real eapi hash when the
  /// stored hash is a webpage short hash (see `getBookInfo`).
  final String? title;

  /// The book's webpage path (`/book/{hash}/{slug}.html`) when the
  /// list response that produced this book carried it. Used only to
  /// fetch the detail-page metadata (volume / ISBN / IPFS) that the
  /// eapi does not carry; null skips that fetch silently.
  final String? href;

  BookIdentifier(this.bookId, this.hashId, {this.title, this.href});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BookIdentifier &&
        other.bookId == bookId &&
        other.hashId == hashId &&
        other.title == title &&
        other.href == href;
  }

  @override
  int get hashCode =>
      bookId.hashCode ^ hashId.hashCode ^ title.hashCode ^ href.hashCode;
}
