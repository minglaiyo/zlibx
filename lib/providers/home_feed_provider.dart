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
  final random = Random();
  const target = 50;
  for (var attempt = 0; attempt < 3; attempt++) {
    final books = await _randomCategoryBooks(
      api,
      random,
      target,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (books.isNotEmpty) {
      return books.map((b) => b.toDisplay()).toList();
    }
  }
  return <DisplayBook>[];
});

/// 从一个随机分类里取 [target] 本书：先取第 1 页拿到总页数，再随机取
/// 一页，不够时顺取下一页补满（最多 3 次请求）。去掉已下架的书，按 id
/// 去重。分类为空时返回空列表，由调用方换分类重试；第 1 页取书失败时
/// 抛错（首页显示错误 / 重试入口）。
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

  final first = await fetchPage(1);
  if (!first.success || first.data == null) {
    throw StateError(first.error ?? 'Failed to load random books');
  }
  final totalPages = first.data!.totalPages ?? 1;
  final total = totalPages < 1 ? 1 : totalPages;
  final page = 1 + random.nextInt(total);
  final collected = <Book>[];
  final seen = <int>{};
  void addPage(CategoryPage pg) {
    for (final cb in pg.books) {
      if (cb.removed) continue;
      if (seen.add(cb.book.id)) collected.add(cb.book);
    }
  }
  var fetches = 1;
  if (page == 1) {
    addPage(first.data!);
  } else {
    final res = await fetchPage(page);
    if (res.success && res.data != null) {
      addPage(res.data!);
      fetches++;
    } else {
      // 随机页失败：用已取到的第 1 页兜底。
      addPage(first.data!);
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
  if (collected.length < target && page != 1) {
    addPage(first.data!);
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
