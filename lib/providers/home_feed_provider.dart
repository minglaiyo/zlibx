// Split out of `books_provider.dart` (M3): home feed: most-popular / recommended / random / recent.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/book_categories.dart';
import '../models/display_book.dart';
import '../services/category_repository.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import 'zlibrary_provider.dart';

// ── Book Lists ──────────────────────────────────────────────────────

final mostPopularBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getMostPopular();
  if (!response.success) {
    // Surface the failure as AsyncError so the UI shows its error/retry
    // branch — an API failure and a genuinely empty list must not look
    // identical (and only the former is retryable).
    throw StateError(response.error ?? 'Failed to load popular books');
  }
  return response.data ?? [];
});

final recommendedBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getUserRecommended();
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load recommendations');
  }
  return response.data ?? [];
});

/// 首页随机推荐：每次刷新从全部 841 个分类里随机挑一个分类，随机取
/// 一页，补满 50 本。不走推荐接口（/eapi/user/book/recommended）也
/// 不走热门接口（/eapi/book/most-popular 及 popular 排序搜索）。每次
/// 打开 / 下拉刷新都重新随机（用户 2026-11-13 定：每次刷新都换）。
/// 分类浏览是 HTML 页（getCategoryBooks），一页约 50 本；页数不够时
/// 顺取下一页补满，最多取 3 页。分类为空时换一个分类重试，最多 3 个。
///
/// 提速（2026-11-13）：每批展示后在后台预取下一批，下次刷新直接
/// 取，免掉 2~3 次顺序取页（被墙时每次都可能走 WebView solver）。
/// 预取只存一批、失败不报错；账号切换时失效（取用时核对账号 id）。
/// 另外记下各分类的总页数（本会话内），已知时跳过第 1 页直取随机页。
final randomBooksProvider = FutureProvider<List<DisplayBook>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  // Read, do NOT watch, the auth state: this provider is invalidated
  // explicitly on every account switch (invalidateAccountScopedProviders),
  // so a reactive watch is unnecessary — and a watch makes the adopt
  // flow a cycle (CircularDependencyError in
  // adopt_webview_session_test, build #249): AuthNotifier invalidates
  // this provider from adoptWebViewSession/logout while it watches
  // authProvider. Every other authProvider access in the providers
  // layer uses ref.read for the same reason.
  final user = ref.read(authProvider).user;
  final userId = user?.id;
  final userKey = user?.remixUserkey;
  // Serve a prefetched batch instantly when one is ready for this
  // account, and roll a fresh prefetch for the next refresh.
  final prefetched = _prefetchedBatch;
  if (prefetched != null &&
      prefetched.isNotEmpty &&
      _prefetchedBatchUserId == userId) {
    _prefetchedBatch = null;
    _prefetchedBatchUserId = null;
    unawaited(_prefetchNextBatch(api, userId: userId, userKey: userKey));
    return prefetched;
  }
  _prefetchedBatch = null;
  _prefetchedBatchUserId = null;
  final random = Random();
  const target = 50;
  for (var attempt = 0; attempt < 3; attempt++) {
    final books = await _randomCategoryBooks(
      api,
      random,
      target,
      userId: userId,
      userKey: userKey,
    );
    if (books.isNotEmpty) {
      final result = books.map((b) => b.toDisplay()).toList();
      unawaited(_prefetchNextBatch(api, userId: userId, userKey: userKey));
      return result;
    }
  }
  return <DisplayBook>[];
});

/// 后台预取的下一批随机推荐 + 它属于的账号。只存一批。
List<DisplayBook>? _prefetchedBatch;
String? _prefetchedBatchUserId;
bool _prefetching = false;

/// 在后台滚下一批随机推荐，存到 [_prefetchedBatch] 供下次刷新直接
/// 取。Best-effort：失败（网络/墙）不报错，下次刷新走正常取页。
/// 只用传进来的 api 与账号值，不碰 ref——预取活得比某次 provider
/// 构建久，构建结束后 ref 不能再用。
Future<void> _prefetchNextBatch(
  ZLibraryApi api, {
  String? userId,
  String? userKey,
}) async {
  if (_prefetching) return;
  _prefetching = true;
  try {
    final random = Random();
    const target = 50;
    for (var attempt = 0; attempt < 3; attempt++) {
      final books = await _randomCategoryBooks(
        api,
        random,
        target,
        userId: userId,
        userKey: userKey,
      );
      if (books.isNotEmpty) {
        _prefetchedBatch = books.map((b) => b.toDisplay()).toList();
        _prefetchedBatchUserId = userId;
        return;
      }
    }
  } catch (_) {
    // Best-effort only: a failed prefetch just means the next refresh
    // fetches live. Never surface prefetch errors.
  } finally {
    _prefetching = false;
  }
}

/// 各分类的总页数（本会话内）。分类总页数变得慢，记下来后下次抽
/// 到同一分类可跳过第 1 页直取随机页，省一次顺序取页。
final Map<int, int> _categoryTotalPages = {};

/// 从一个随机分类里取 [target] 本书：先取第 1 页拿到总页数（本会话
/// 已知的跳过），再随机取一页，不够时顺取下一页补满（最多 3 次
/// 请求）。去掉已下架的书，按 id 去重。分类为空时返回空列表，由
/// 调用方换分类重试；第 1 页取书失败时抛错（首页显示错误 / 重试入口）。
///
/// 每页都是 Dio 先取、墙一拦就走无头 WebView solver——跟搜索页分类
/// 浏览（SearchNotifier._fetchCategory）同一个兜底。没有它时，被墙
/// 的线路上首页直接报错，而搜索页的分类能出（2026-11-13，开关开着
/// 报错、关着没事，用户设备实测）。
Future<List<Book>> _randomCategoryBooks(
  ZLibraryApi api,
  Random random,
  int target, {
  String? userId,
  String? userKey,
}) async {
  final repo = CategoryRepository(api);
  final categoryIds = kBookCategoryParents.keys.toList();
  final categoryId = categoryIds[random.nextInt(categoryIds.length)];

  Future<ApiResponse<CategoryPage>> fetchPage(int page) async {
    var response = await repo.fetchBooks(categoryId: categoryId, page: page);
    if (!response.success && repo.isChallengeError(response.error)) {
      final url = repo.categoryPageUrl(categoryId: categoryId, page: page);
      final html = await repo.fetchViaSolver(
        url,
        userId: userId,
        userKey: userKey,
      );
      if (html != null) {
        final parsed = repo.parseBooks(html, baseUrl: Uri.parse(url).origin);
        if (parsed != null) {
          response = ApiResponse.ok(parsed);
        }
      }
    }
    return response;
  }

  final collected = <Book>[];
  final seen = <int>{};
  void addPage(CategoryPage pg) {
    for (final cb in pg.books) {
      if (cb.removed) continue;
      if (seen.add(cb.book.id)) collected.add(cb.book);
    }
  }

  var total = _categoryTotalPages[categoryId];
  CategoryPage? firstPage;
  var fetches = 0;
  if (total == null) {
    final first = await fetchPage(1);
    if (!first.success || first.data == null) {
      throw StateError(first.error ?? 'Failed to load random books');
    }
    firstPage = first.data;
    total = firstPage.totalPages ?? 1;
    if (total < 1) total = 1;
    _categoryTotalPages[categoryId] = total;
    fetches = 1;
  }
  final page = 1 + random.nextInt(total);
  if (page == 1 && firstPage != null) {
    addPage(firstPage);
  } else {
    final res = await fetchPage(page);
    if (res.success && res.data != null) {
      final pg = res.data!;
      // 每页都带同样的 pagerOptions 总数，顺手刷新缓存与本地 total。
      final t = pg.totalPages;
      if (t != null && t >= 1) {
        _categoryTotalPages[categoryId] = t;
        total = t;
      }
      addPage(pg);
      fetches++;
      if (collected.isEmpty && firstPage == null) {
        // 随机页为空且无第 1 页可兜底（totalPages 来自过期的缓存）：
        // 重读第 1 页拿新鲜的书与总数。
        final fb = await fetchPage(1);
        if (fb.success && fb.data != null) {
          addPage(fb.data!);
          fetches++;
        }
      }
    } else if (firstPage != null) {
      // 随机页失败：用已取到的第 1 页兜底。
      addPage(firstPage);
    } else {
      // 随机页失败且无第 1 页可兜底：取第 1 页兜底。
      final fb = await fetchPage(1);
      if (fb.success && fb.data != null) {
        addPage(fb.data!);
        fetches++;
      }
    }
  }
  var next = page + 1;
  while (collected.length < target && next <= total && fetches < 3) {
    final res = await fetchPage(next);
    if (!res.success || res.data == null) break;
    addPage(res.data!);
    fetches++;
    next++;
  }
  if (collected.length < target && page != 1 && firstPage != null) {
    addPage(firstPage);
  }
  return collected.take(target).toList();
}

/// 首页推荐：开关（randomRecommendProvider，设置页，默认关）开时用
/// 随机分类推荐（randomBooksProvider），关时用个性化推荐
///（recommendedBooksProvider，/eapi/user/book/recommended）。
/// 开关关是之前一直能用的首页；随机那条路走分类 HTML 页，某些线路
/// 被墙时会直接报错，开关让用户随时切回能用的那一路。
final homeRecommendedProvider = Provider<AsyncValue<List<DisplayBook>>>((ref) {
  final useRandom = ref.watch(randomRecommendProvider);
  if (useRandom) {
    return ref.watch(randomBooksProvider);
  }
  // whenData keeps loading/error states as-is: the home screen keeps its
  // error/retry entry and keeps showing the previous data while a
  // revalidation after an account switch is in flight.
  return ref.watch(recommendedBooksProvider).whenData(
    (books) => books.map((b) => b.toDisplay()).toList(),
  );
});

final recentBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getRecently();
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load recent books');
  }
  return response.data ?? [];
});
