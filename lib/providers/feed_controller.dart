import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../models/display_book.dart';
import '../services/home_feed_page_cache.dart';
import '../services/random_feed_cache.dart';
import 'auth_provider.dart';
import 'home_feed_provider.dart';
import 'settings_provider.dart';
import 'zlibrary_provider.dart';

/// 信息流（2026-11-20，用户定）：推荐 / 热门 / 最新三个面从"单批展示 /
/// 翻页替换"改成上滑自动加载下一页的**累积信息流**。
///
/// [FeedState] 三份共享：books 累积、isLoading 首屏（重开 app 直出持久
/// 缓存时它一帧都不亮）、isLoadingMore 上滑加载中、hasMore 是否还有
/// 下一页、error 首屏错误（只有 books 为空时才顶成错误页——有旧内容时
/// 静默保旧，别让一次网络抖动把已滚到的信息流掀了）。
class FeedState {
  final List<DisplayBook> books;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;

  const FeedState({
    this.books = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.error,
  });

  FeedState copyWith({
    List<DisplayBook>? books,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error,
  }) => FeedState(
    books: books ?? this.books,
    isLoading: isLoading ?? this.isLoading,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
    error: error,
  );
}

/// 热门 / 最新共用的分页累积骨架：第 1 页可带持久缓存（重开 app 直出，
/// 后台静默换新），loadMore 顺序吃页、按 id 去重，整页全是重复时自动
/// 翻到下一个有新书的页，页空/失败各有归宿。
abstract class PagedFeedController extends Notifier<FeedState> {
  /// 持久缓存里上一批第 1 页；没有就 null。
  List<Book>? readCache();

  /// 把新的第 1 页写回持久缓存。
  Future<void> persistCache(List<Book> books);

  /// 第 1 页：热门走 eapi 快照（镜像上自动回退 popular 排序搜索），
  /// 最新走 date 排序搜索（recently 端点在真实线路上只回空壳，插件
  /// 本来就活在搜索回退上，直接走源）。
  Future<List<Book>> fetchInitialPage();

  /// 第 [page] 页（loadMore 用）。失败抛异常/返回 null 都行——由
  /// loadMore 统一兜。
  Future<List<Book>?> fetchPage(int page);

  /// loadMore 的翻页上限：热门排序越往后越冷门，深页换来的多样性和
  /// 把信息流拖没的速度不成比例（与随机推荐的页码窗口同一理由）；最新
  /// 是时间序，自然延续，上限给得宽。
  int get maxLoadMorePages;

  /// 续页游标的起点：第 1 页如果不是搜索源本身（热门的 eapi 快照），
  /// 续页从搜索第 1 页开始；第 1 页就是搜索源（最新的 date 搜索）时
  /// 从第 2 页续。
  int get firstLoadMorePage;

  int _nextPage = 1;
  final Set<String> _seenIds = <String>{};

  @override
  FeedState build() {
    // Notifier 实例在 invalidate 后复用：游标与去重集必须逐字段归位，
    // 否则上一条会话的翻页游标会漏给下一次。
    _nextPage = 1;
    _seenIds.clear();
    final cached = readCache();
    if (cached != null && cached.isNotEmpty) {
      final books = cached.map((b) => b.toDisplay()).toList();
      _seenIds.addAll(books.map((b) => b.id));
      _nextPage = firstLoadMorePage;
      unawaited(_loadFirstPage(settleCache: true));
      return FeedState(books: books, hasMore: true);
    }
    unawaited(_loadFirstPage(settleCache: false));
    return const FeedState(isLoading: true);
  }

  /// 第 1 页加载（首建 / 下拉刷新共用）。缓存直出的那批会被静默换新。
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);
    await _loadFirstPage(settleCache: false);
  }

  Future<void> _loadFirstPage({required bool settleCache}) async {
    try {
      final rawBooks = await fetchInitialPage();
      final books = rawBooks.map((b) => b.toDisplay()).toList();
      if (books.isNotEmpty) {
        _seenIds
          ..clear()
          ..addAll(books.map((b) => b.id));
        _nextPage = firstLoadMorePage;
        state = state.copyWith(
          books: books,
          isLoading: false,
          hasMore: true,
          error: null,
        );
        if (!settleCache) unawaited(persistCache(rawBooks));
      } else if (state.books.isEmpty) {
        // 真空：接口成功但没书（新装/源耗尽），空态而不是错误。
        state = state.copyWith(isLoading: false, hasMore: false, error: null);
      } else {
        // 有旧内容但新一轮空了：保旧（别掀掉用户已滚到的信息流）。
        state = state.copyWith(isLoading: false, hasMore: false, error: null);
      }
    } on Object catch (error) {
      if (state.books.isEmpty) {
        state = state.copyWith(isLoading: false, error: error);
      } else {
        // 有旧内容：静默保旧，保持 hasMore，用户还能继续滚/再刷。
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// 上滑加载下一页：顺序吃页、按 id 去重，整页重复就自动翻到下一个
  /// 有新书的页；页空 = 源耗尽（hasMore 收口），失败 = 保 hasMore，
  /// 下次滚动原地再试。
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    state = state.copyWith(isLoadingMore: true);
    try {
      final added = <DisplayBook>[];
      var page = _nextPage;
      var exhausted = false;
      while (added.isEmpty && page <= maxLoadMorePages) {
        final books = await fetchPage(page);
        if (books == null || books.isEmpty) {
          exhausted = true;
          break;
        }
        for (final book in books) {
          final display = book.toDisplay();
          if (_seenIds.add(display.id)) added.add(display);
        }
        if (added.isEmpty) page++; // 整页都是重复：跳到下一页
      }
      if (added.isEmpty) {
        _nextPage = exhausted ? page : page + 1;
        state = state.copyWith(isLoadingMore: false, hasMore: false);
      } else {
        _nextPage = page + 1;
        state = state.copyWith(
          books: [...state.books, ...added],
          isLoadingMore: false,
        );
      }
    } on Object catch (_) {
      // 网络抖动/墙：保持 hasMore 与游标，下次滚动原地再试。
      state = state.copyWith(isLoadingMore: false);
    }
  }
}

/// 热门信息流：第 1 页 = eapi 快照（getMostPopular，镜像上自动回退），
/// 后续页 = popular 排序搜索（快照端点无视 page——2026-11-20 实测——
/// 所以续页必须走可翻页的搜索源）。
class PopularFeedController extends PagedFeedController {
  @override
  List<Book>? readCache() => HomeFeedPageCache.popular();

  @override
  Future<void> persistCache(List<Book> books) =>
      HomeFeedPageCache.savePopular(books);

  @override
  Future<List<Book>> fetchInitialPage() async {
    final response = await ref.read(zlibraryApiProvider).getMostPopular(
      page: 1,
    );
    if (!response.success) {
      throw StateError(response.error ?? 'Failed to load popular books');
    }
    return response.data ?? [];
  }

  @override
  Future<List<Book>?> fetchPage(int page) async {
    final response = await ref.read(zlibraryApiProvider).search(
      order: 'popular',
      limit: 50,
      page: page,
    );
    if (!response.success) return null;
    return response.data ?? [];
  }

  @override
  int get maxLoadMorePages => 15;

  @override
  int get firstLoadMorePage => 1;
}

/// 最新信息流：date 排序搜索直取（理由见 [PagedFeedController.fetchInitialPage]）。
class RecentFeedController extends PagedFeedController {
  @override
  List<Book>? readCache() => HomeFeedPageCache.recent();

  @override
  Future<void> persistCache(List<Book> books) =>
      HomeFeedPageCache.saveRecent(books);

  @override
  Future<List<Book>> fetchInitialPage() async {
    final response = await ref.read(zlibraryApiProvider).search(
      order: 'date',
      limit: 50,
      page: 1,
    );
    if (!response.success) {
      throw StateError(response.error ?? 'Failed to load recent books');
    }
    return response.data ?? [];
  }

  @override
  Future<List<Book>?> fetchPage(int page) async {
    final response = await ref.read(zlibraryApiProvider).search(
      order: 'date',
      limit: 50,
      page: page,
    );
    if (!response.success) return null;
    return response.data ?? [];
  }

  @override
  int get maxLoadMorePages => 200;

  @override
  int get firstLoadMorePage => 2;
}

final popularFeedProvider = NotifierProvider<PopularFeedController, FeedState>(
  PopularFeedController.new,
);

final recentFeedProvider = NotifierProvider<RecentFeedController, FeedState>(
  RecentFeedController.new,
);

/// 首页推荐信息流：随机开关开 = 随机批累积（每批 50 本，抽样机与持久
/// 缓存复用 [fetchRandomFeedBatch]）；关 = 个性化推荐单批（端点无翻页
/// 参数，hasMore 恒 false，不画加载行）。
class HomeFeedController extends Notifier<FeedState> {
  @override
  FeedState build() {
    final useRandom = ref.watch(randomRecommendProvider);
    final api = ref.read(zlibraryApiProvider);
    final user = ref.read(authProvider).user;
    final userId = user?.id;
    final userKey = user?.remixUserkey;
    if (useRandom) {
      // 启动缓存：重开 app 直出上一批（零转圈），后台预滚新批供上滑。
      final cached = RandomFeedCache.readSync(userId);
      if (cached != null && cached.isNotEmpty) {
        unawaited(
          prefetchRandomBatch(api, userId: userId, userKey: userKey),
        );
        return FeedState(
          books: cached.map((b) => b.toDisplay()).toList(),
          hasMore: true,
        );
      }
      unawaited(_loadRandomFirstBatch(api, userId, userKey));
      return const FeedState(isLoading: true);
    }
    unawaited(_loadPersonalized(api));
    return const FeedState(isLoading: true);
  }

  Future<void> _loadRandomFirstBatch(
    ZLibraryApi api,
    String? userId,
    String? userKey,
  ) async {
    try {
      final batch = await fetchRandomFeedBatch(
        api: api,
        userId: userId,
        userKey: userKey,
        serveFromCache: false,
      );
      state = FeedState(books: batch, hasMore: batch.isNotEmpty);
    } on Object catch (error) {
      state = FeedState(error: error);
    }
  }

  Future<void> _loadPersonalized(ZLibraryApi api) async {
    try {
      final response = await api.getUserRecommended();
      if (!response.success) {
        throw StateError(response.error ?? 'Failed to load recommendations');
      }
      state = FeedState(
        books: (response.data ?? []).map((b) => b.toDisplay()).toList(),
        hasMore: false,
      );
    } on Object catch (error) {
      // 失败保旧：有旧内容时静默保留（别让一次网络抖动掀掉已滚到的
      // 流，与 [FeedState] 文档的 error 语义一致）；books 空时（首载/
      // 空流刷新）顶错误页，error != null 时 UI 给重试按钮。曾经这里
      // 用 FeedState(error:) 整表替换清空 books、又被 refresh 收尾的
      // copyWith 无条件抹掉 error，网络抖一次推荐流就变成"无书"空态
      // （审查 P1-2）。
      state = state.copyWith(
        isLoading: false,
        error: state.books.isEmpty ? error : null,
      );
    }
  }

  /// 下拉刷新：随机 = 换一批新的替换（重新随机，用户 2026-11-13 定）；
  /// 个性化 = 重拉单批。
  Future<void> refresh() async {
    final useRandom = ref.read(randomRecommendProvider);
    final api = ref.read(zlibraryApiProvider);
    final user = ref.read(authProvider).user;
    state = state.copyWith(isLoading: true, error: null);
    try {
      if (useRandom) {
        final batch = await fetchRandomFeedBatch(
          api: api,
          userId: user?.id,
          userKey: user?.remixUserkey,
          serveFromCache: false,
        );
        state = FeedState(books: batch, hasMore: batch.isNotEmpty);
      } else {
        // 成败都在 _loadPersonalized 内部收尾（isLoading/error 各归其
        // 位）。这里不能补 copyWith(isLoading:false)——copyWith 的
        // error 是无条件覆盖，会把失败刚写入的错误页抹成"无书"空态
        // （审查 P1-2）。
        await _loadPersonalized(api);
      }
    } on Object catch (error) {
      // 有旧内容保旧；空流顶错误页。
      state = state.copyWith(
        isLoading: false,
        error: state.books.isEmpty ? error : null,
      );
    }
  }

  /// 上滑加载下一随机批：按 id 去重，整批重复就再抽（最多 3 次），
  /// 抽不出新书就收口（疲劳名单循环回来了）。
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    final useRandom = ref.read(randomRecommendProvider);
    if (!useRandom) return; // 个性化单批，无更多
    state = state.copyWith(isLoadingMore: true);
    try {
      final api = ref.read(zlibraryApiProvider);
      final user = ref.read(authProvider).user;
      final seen = state.books.map((b) => b.id).toSet();
      var added = <DisplayBook>[];
      for (var attempt = 0; attempt < 3 && added.isEmpty; attempt++) {
        final batch = await fetchRandomFeedBatch(
          api: api,
          userId: user?.id,
          userKey: user?.remixUserkey,
          serveFromCache: false,
        );
        added = [
          for (final book in batch)
            if (seen.add(book.id)) book,
        ];
      }
      state = added.isEmpty
          ? state.copyWith(isLoadingMore: false, hasMore: false)
          : state.copyWith(
              books: [...state.books, ...added],
              isLoadingMore: false,
            );
    } on Object catch (_) {
      // 抖动/墙：保持 hasMore，下次滚动原地再试。
      state = state.copyWith(isLoadingMore: false);
    }
  }
}

final homeFeedProvider = NotifierProvider<HomeFeedController, FeedState>(
  HomeFeedController.new,
);
