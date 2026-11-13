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

/// 缓存键：详情页的 PATH（每版本稳定）。手动剥掉 query/fragment，
/// 不走 Uri.parse——它会把这个未编码的中文路径百分号编码，同一个
/// href 的键就因写法不同而漂移（CI 2026-11-13：测试夹具的中文 slug
/// 被编码成 %E5%90%88…，缓存全 miss）。
String _detailExtrasKey(String href) {
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
  return DateTime.now().millisecondsSinceEpoch - fetchedAt <
      _bookDetailExtrasTtl.inMilliseconds;
}

/// [BookDetailMetadata] → 可持久化的 JSON（7 个字段；fetchedAt 由
/// storage 层盖章）。
Map<String, dynamic> _extrasJsonOf(BookDetailMetadata metadata) => {
      'volume': metadata.volume,
      'isbn10': metadata.isbn10,
      'isbn13': metadata.isbn13,
      'ipfsCid': metadata.ipfsCid,
      'ipfsCidBlake2b': metadata.ipfsCidBlake2b,
      'ratingInterest': metadata.ratingInterest,
      'ratingQuality': metadata.ratingQuality,
    };

/// 缓存 JSON → 合并进书本体。逐字段容错取值：缓存是手改/旧版本的
/// JSON 时最坏也只是丢字段，绝不让详情页报错。
String? _extrasString(Object? value) => value is String ? value : null;

Book _applyExtrasJson(Book book, Map<String, dynamic> extras) =>
    book.copyWith(
      volume: _extrasString(extras['volume']),
      isbn10: _extrasString(extras['isbn10']),
      isbn13: _extrasString(extras['isbn13']),
      ipfsCid: _extrasString(extras['ipfsCid']),
      ipfsCidBlake2b: _extrasString(extras['ipfsCidBlake2b']),
      ratingInterest: _extrasString(extras['ratingInterest']),
      ratingQuality: _extrasString(extras['ratingQuality']),
    );

/// autoDispose：详情页关掉后无人 watch 即释放缓存。此前常驻内存，
/// 长会话逐本累积（每本详情是全量 [Book]）；相似书链路中每一页
/// 详情始终 watch 自己的 identifier，不会产生重复请求。
///
/// 返回书本体（eapi 详情 + 详情页 HTML 合并进来的 卷/ISBN/IPFS/评分
/// 字段），来自同一次 HTML 抓取（[ZLibraryApi.fetchBookDetailExtras]）。
///
/// 加载顺序（2026-11-13 重排；此前 HTML 严格排在 eapi 之后、且每次
/// 打开都重新下载几百 KB 的详情页）：
///
/// 1. 路由参数自带 href（搜索/列表结果都带）且持久缓存新鲜 →
///    **整段跳过 HTML 下载**，eapi 小 JSON 一到即用缓存字段合并上
///    屏——重复打开（7 天内）内容体即时完整。
/// 2. 缓存未命中或过期 → href 已知时 **HTML 与 eapi 并行**发起，
///    总时延取 max 而非相加；两源都到再合并，新字段回写缓存。
/// 3. HTML 失败 → 回退用过期缓存字段（比没有强）；都没有才返回
///    纯 eapi 书。eapi 本身的失败照旧抛出（页面显示错误 + 重试）。
/// 4. 路由参数没有 href → eapi 之后用其 href 串行抓（旧行为）。
final bookDetailsProvider =
    FutureProvider.autoDispose.family<Book, BookIdentifier>(
  (ref, identifier) async {
  final api = ref.watch(zlibraryApiProvider);
  final storage = ref.watch(storageServiceProvider);

  /// 抓 HTML 附加信息，成功时回写缓存并返回字段 JSON；失败返回
  /// null（异常折进结果——并行启动的这条不能以未处理异常炸掉）。
  Future<Map<String, dynamic>?> fetchExtrasJson(String href) async {
    try {
      final user = ref.read(authProvider).user;
      final pageRepo = BookDetailPageRepository(api);
      final result = await pageRepo.fetch(
        href: href,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (!result.success || result.data == null) {
        logIgnored(
          'book_details_metadata',
          StateError(result.error ?? 'book detail page failed'),
        );
        return null;
      }
      final json = _extrasJsonOf(result.data!.metadata);
      unawaited(storage.mergeBookDetailExtras(_detailExtrasKey(href), json));
      return json;
    } catch (error) {
      logIgnored('book_details_metadata', error);
      return null;
    }
  }

  // 路由参数的 href 先查缓存：新鲜 → 不发 HTML 请求；否则立即并行
  // 发出（与下面的 eapi 详情同时跑）。
  final routeHref = identifier.href;
  final routeKey = (routeHref == null || routeHref.isEmpty)
      ? null
      : _detailExtrasKey(routeHref);
  final routeExtras =
      routeKey == null ? null : storage.getBookDetailExtrasSync(routeKey);
  final routeFresh = routeExtras != null && _extrasFresh(routeExtras);
  final routeFetch = (routeKey != null && !routeFresh)
      ? fetchExtrasJson(routeHref!)
      : null;

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
  final href = routeHref ?? book.href;
  if (href == null || href.isEmpty) {
    return book;
  }
  final hrefKey = _detailExtrasKey(href);
  final cached = routeKey == hrefKey
      ? routeExtras
      : storage.getBookDetailExtrasSync(hrefKey);

  // 并行抓取在途（缓存未命中或过期）：等它——成功用新值，失败用过
  // 期缓存兜底，都没有就返回纯 eapi 书。
  if (routeFetch != null) {
    final fetched = await routeFetch;
    if (fetched != null) {
      return _applyExtrasJson(book.copyWith(href: href), fetched);
    }
    if (cached != null) {
      return _applyExtrasJson(book.copyWith(href: href), cached);
    }
    return book.copyWith(href: href);
  }
  // 新鲜缓存：整段跳过 HTML 下载，eapi 一到即完整。
  if (cached != null) {
    return _applyExtrasJson(book.copyWith(href: href), cached);
  }
  // 无缓存且路由没带 href（book.href 才有）：串行抓——旧行为。
  final fetched = await fetchExtrasJson(href);
  if (fetched != null) {
    return _applyExtrasJson(book.copyWith(href: href), fetched);
  }
  return book.copyWith(href: href);
  },
);

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
