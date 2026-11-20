// Split out of `books_provider.dart` (M3): home feed: most-popular / recommended / random / recent.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/book_categories.dart';
import '../models/display_book.dart';
import '../services/category_repository.dart';
import '../services/random_feed_cache.dart';
import '../services/random_feed_history.dart';
import '../services/storage_service.dart';
import '../utils/diagnostics.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import 'zlibrary_provider.dart';


// ── Book Lists ──────────────────────────────────────────────────────

// 热门 / 最新两页已改信息流（2026-11-20）：数据与翻页规则在
// feed_controller.dart 的 PopularFeedController / RecentFeedController，
// 启动缓存 HomeFeedPageCache 由控制器的首屏加载直接使用。旧的
// family 页码 provider（mostPopularBooksProvider / recentBooksProvider）
// 随翻页替换的交互一并退役。

final recommendedBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getUserRecommended();
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load recommendations');
  }
  return response.data ?? [];
});

/// 首页随机推荐：每次刷新两级抽一个分类（见 [pickRandomCategoryId]）、
/// 在页码窗口里抽一页（见 [pickRandomPage]），补满 50 本，再跳过最近
/// 看过的与收藏的（见 [excludedBookIdsFor] / [pickUnseen]）。不走推荐
/// 接口（/eapi/user/book/recommended）也不走热门接口（/eapi/book/
/// most-popular 及 popular 排序搜索）。
/// 分类浏览是 HTML 页（getCategoryBooks），一页约 50 本；不够时顺取下
/// 一页补满，最多取 3 页。分类为空时换一个分类重试，最多 3 个。
///
/// 刷新语义（用户 2026-11-13 定：每次刷新都换）不变；2026-11-20 加
/// 启动缓存（[RandomFeedCache]，用户定）：**重开 app 的第一次构建**
/// 直接端出上一批的持久缓存——零请求零转圈——同时后台滚新的一批供
/// 下拉刷新秒出；本会话后续的刷新/失效照旧走预取/现抓，不吃缓存
/// （见 [_cacheServedThisSession]）。
///
/// 提速（2026-11-13）：每批展示后在后台预取下一批，下次刷新直接
/// 取，免掉 2~3 次顺序取页（被墙时每次都可能走 WebView solver）。
/// 预取只存一批、失败不报错；账号切换时失效（取用时核对账号 id）。
/// 另外记下各分类的总页数（本会话内），已知时跳过第 1 页直取随机页。
///
/// 随机推荐改信息流（2026-11-20）后，本 provider 只剩"单批取一批"
/// 一个薄壳，批次生成逻辑全部在 [fetchRandomFeedBatch]（首页信息流
/// 控制器逐批调用它）。
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
  return fetchRandomFeedBatch(
    api: api,
    userId: user?.id,
    userKey: user?.remixUserkey,
  );
});

/// 生成一批随机推荐（启动缓存 → 预取批 → 现抽，三级依次），记账 /
/// 落盘 / 预滚下一批都在这里完成。首页信息流控制器每上滑一屏就调
/// 它一次；[randomBooksProvider] 是它的单批薄壳。
Future<List<DisplayBook>> fetchRandomFeedBatch({
  required ZLibraryApi api,
  String? userId,
  String? userKey,
  bool serveFromCache = true,
}) async {
  // 启动缓存：本会话第一次调用端出上一批（重开 app 零转圈），同时
  // 后台滚新的一批。缓存那批跨会话已在疲劳名单里，预滚的新批不会
  // 撞上它。
  if (serveFromCache && !_cacheServedThisSession) {
    _cacheServedThisSession = true;
    final cached = RandomFeedCache.readSync(userId);
    if (cached != null && cached.isNotEmpty) {
      unawaited(prefetchRandomBatch(api, userId: userId, userKey: userKey));
      return cached.map((b) => b.toDisplay()).toList();
    }
  }
  // Serve a prefetched batch instantly when one is ready for this
  // account, and roll a fresh prefetch for the next refresh.
  final prefetched = _prefetchedBatch;
  if (prefetched != null &&
      prefetched.isNotEmpty &&
      _prefetchedBatchUserId == userId) {
    _prefetchedBatch = null;
    _prefetchedBatchUserId = null;
    final result = prefetched.map((b) => b.toDisplay()).toList();
    _recordShown(result);
    unawaited(RandomFeedCache.persist(userId, prefetched));
    unawaited(prefetchRandomBatch(api, userId: userId, userKey: userKey));
    return result;
  }
  _prefetchedBatch = null;
  _prefetchedBatchUserId = null;
  final random = _feedRandom();
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
      _recordShown(result);
      unawaited(RandomFeedCache.persist(userId, books));
      unawaited(prefetchRandomBatch(api, userId: userId, userKey: userKey));
      return result;
    }
  }
  return <DisplayBook>[];
}

/// 记下这一批真的露过面（疲劳名单的唯一写入点）。
///
/// 只在"这一批要被返回给首页"时记，不在 [prefetchRandomBatch] 里记：
/// 预取的那批用户不一定刷新去取，账号一换就作废，提前记账会把没露过
/// 面的书算成看过的，白堵后面的抽样。
///
/// 记账是同步的（[RandomFeedHistory] 的内存镜像当场生效，落盘在后台），
/// 所以紧随其后的那次预取抽到的批次一定不含刚展示的书——只等硬盘写
/// 完的话，这里就有个竞态窗口。
void _recordShown(List<DisplayBook> books) {
  RandomFeedHistory.recordShown([for (final b in books) b.id]);
}

/// 后台预取的下一批随机推荐（[Book] 形态，端给首页时才转
/// [DisplayBook]，落缓存也直接用它）+ 它属于的账号。只存一批。
List<Book>? _prefetchedBatch;
String? _prefetchedBatchUserId;
bool _prefetching = false;

/// 启动缓存是否已在本会话端出过：只有重开 app 后的第一次构建吃
/// 缓存，之后的刷新/失效必须拿新批——不然"刷新内容不变"的老毛病
/// 回归（详见 randomBooksProvider 的注释）。
bool _cacheServedThisSession = false;

/// 在后台滚下一批随机推荐，存到 [_prefetchedBatch] 供下次刷新直接
/// 取。Best-effort：失败（网络/墙）不报错，下次刷新走正常取页。
/// 只用传进来的 api 与账号值，不碰 ref——预取活得比某次 provider
/// 构建久，构建结束后 ref 不能再用。
Future<void> prefetchRandomBatch(
  ZLibraryApi api, {
  String? userId,
  String? userKey,
}) async {
  if (_prefetching) return;
  _prefetching = true;
  try {
    final random = _feedRandom();
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
        _prefetchedBatch = books;
        _prefetchedBatchUserId = userId;
        return;
      }
    }
  } catch (error) {
    // Best-effort only: a failed prefetch just means the next refresh
    // fetches live. Never surface prefetch errors — but log them
    // (审查 v2 P2-2)：release 的诊断轨迹里看得到预取失败率。
    logIgnored('feed_prefetch', error);
  } finally {
    _prefetching = false;
  }
}

/// 各分类的总页数（本会话内）。分类总页数变得慢，记下来后下次抽
/// 到同一分类可跳过第 1 页直取随机页，省一次顺序取页。
final Map<int, int> _categoryTotalPages = {};

/// 测试用：清掉随机推荐的本会话全局态（预取批次 + 分类页数缓存 +
/// 注入的随机源）。这几样是库级单例，用例之间必须互相看不见，否则
/// 上一条测试留下的预取批次会被下一条直接端走，页码抽样也会跳过第 1
/// 页探针。
@visibleForTesting
void resetRandomFeedStateForTest() {
  _prefetchedBatch = null;
  _prefetchedBatchUserId = null;
  _prefetching = false;
  _cacheServedThisSession = false;
  _categoryTotalPages.clear();
  _injectedRandom = null;
}

/// 测试用注入的随机源。给了它，整个抽样序列（分类、页码）就可复现，
/// 断言才谈得上确定；生产代码里它恒为 null，每次都是新 [Random()]。
Random? _injectedRandom;

/// 测试用：固定随机推荐的抽样随机源（传 null 恢复真随机）。
/// 注意是**共享**一份：多次刷新接着同一条随机序列往下抽，跟真机上
/// "每次刷新各自随机"不同的是序列可复现。
@visibleForTesting
void setRandomFeedRandomForTest(Random? random) => _injectedRandom = random;

Random _feedRandom() => _injectedRandom ?? Random();

/// 页码窗口：随机推荐只在每个分类的前这么几页里抽（一页约 50 本，
/// 30 页 ≈ 1500 本的面）。
///
/// 为什么收紧（旧写法是在 1..总页数 全范围均匀抽）：大类的总页数是
/// 几千页，全范围抽几乎必然抽到深页——深页越往后越冷门，而每往深一
/// 页就多一次"分类 HTML 页"请求，被墙的线路上每次都可能落到无头
/// WebView solver 上（一次几秒）。首页一次只要 50 本，深页换来的多样
/// 性抵不上它把首页拖没的速度。
@visibleForTesting
const int kRandomPageWindow = 30;

/// 页码：在 1..min([totalPages], [kRandomPageWindow]) 里均匀抽一个。
@visibleForTesting
int pickRandomPage(Random random, int totalPages) {
  final span = totalPages < 1 ? 1 : min(totalPages, kRandomPageWindow);
  return 1 + random.nextInt(span);
}

/// 两级抽分类：先在一级分类里均匀挑一个门类，再在"它自己 + 它的子
/// 分类"里均匀挑一个。
///
/// 为什么不直接从全部 841 个分类里均匀抽（旧写法）：子类多的门类会把
/// 概率压过去——History 有 49 个子类、Astronomy 只有几个，均匀抽 841
/// 时前者被抽中的概率是后者的十几倍，"随机推荐"实际上一直是那么几个
/// 大门类。两级抽样把门类那一层拉平（每个一级门类等概率），门类内部
/// 再按它自己的子类数分——多样性来自门类之间，而不是某个大类的子类。
@visibleForTesting
int pickRandomCategoryId(Random random) {
  final tops =
      kBookCategoryParents.entries
          .where((e) => e.value == null)
          .map((e) => e.key)
          .toList()
        ..sort();
  final top = tops[random.nextInt(tops.length)];
  final candidates = <int>[
    top,
    ...kBookCategoryParents.entries
        .where((e) => e.value == top)
        .map((e) => e.key),
  ]..sort();
  return candidates[random.nextInt(candidates.length)];
}

/// 从 [books] 里挑一批 [target] 本：先取不在 [excludeIds] 里的，不足
/// 再用看过的补齐（保持页面顺序）。所以去重永远不会把首页抽空——
/// 只要抽到的页里有书，就一定能凑满。
@visibleForTesting
List<Book> pickUnseen(List<Book> books, Set<String> excludeIds, int target) {
  bool isUnseen(Book b) => !excludeIds.contains(b.id.toString());
  final unseen = books.where(isUnseen).toList();
  if (unseen.length >= target) return unseen.take(target).toList();
  final recycled = books.where((b) => !isUnseen(b)).toList();
  return <Book>[...unseen, ...recycled].take(target).toList();
}

/// 这次抽样要跳过的书 id：疲劳名单（最近展示过的）+ 当前账号的收藏。
///
/// 收藏读的是本地缓存（Hive 同步读，[StorageService] 的账号维度
/// favorite_books_账号id 键），不是 savedBooksProvider：那个 notifier 一
/// 构建就去分页拉服务器书架（最多 100 页 × 100 本），首页随机推荐不
/// 该为它排队，更不该在后台预取里排队。本地这份就是书架的镜像（书架
/// 页点心形时两边一起写），未登录时为空——那时只有疲劳名单。
@visibleForTesting
Set<String> excludedBookIdsFor(String? userId) {
  final out = <String>{...RandomFeedHistory.readSync()};
  if (userId != null && userId.isNotEmpty) {
    out.addAll(StorageService().getFavoritesSyncForAccount(userId));
  }
  return out;
}

/// 从一个随机分类里取 [target] 本书：先取第 1 页拿到总页数（本会话
/// 已知的跳过），再在页码窗口里随机取一页，不够时顺取下一页补满（最
/// 多 3 次请求，也补不出窗口）。去掉已下架的书，按 id 去重，最后跳过
/// 疲劳名单与收藏（凑不满时用看过的补）。分类为空时返回空列表，由调用
/// 方换分类重试；第 1 页取书失败时抛错（首页显示错误 / 重试入口）。
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
  final categoryId = pickRandomCategoryId(random);

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
        final parsed = await repo.parseBooks(
          html,
          baseUrl: Uri.parse(url).origin,
        );
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
    final firstData = first.data!;
    firstPage = firstData;
    total = firstData.totalPages ?? 1;
    if (total < 1) total = 1;
    _categoryTotalPages[categoryId] = total;
    fetches = 1;
  }
  final page = pickRandomPage(random, total);
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
  // 补页也走同一个窗口上限：随机页落在窗口末端时不再往深页续。
  // total 可能刚被上面那一页刷新过，所以这里用当下的 total 算。
  final pageLimit = min(total, kRandomPageWindow);
  while (collected.length < target && next <= pageLimit && fetches < 3) {
    final res = await fetchPage(next);
    if (!res.success || res.data == null) break;
    addPage(res.data!);
    fetches++;
    next++;
  }
  if (collected.length < target && page != 1 && firstPage != null) {
    addPage(firstPage);
  }
  return pickUnseen(collected, excludedBookIdsFor(userId), target);
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
  return ref
      .watch(recommendedBooksProvider)
      .whenData((books) => books.map((b) => b.toDisplay()).toList());
});
