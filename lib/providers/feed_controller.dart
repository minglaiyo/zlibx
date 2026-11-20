import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../models/display_book.dart';
import '../services/home_feed_page_cache.dart';
import '../services/random_feed_cache.dart';
import '../utils/diagnostics.dart';
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

  /// 第 [page] 页（loadMore 用）。**失败必须抛异常**——loadMore 的
  /// catch 会保住 hasMore 与游标、下次滚动原地重试；返回空列表才是
  /// "确认空页"（耗尽收口）。曾经把 success:false 折叠成 null 返回，
  /// 一次瞬时失败（cf_blocked/限流）被当成源耗尽，翻页被永久关掉
  /// （审查 P2-3）。[cancelToken] 传给底层请求：轮次被新轮次/新会话
  /// 取消时立即停。
  Future<List<Book>?> fetchPage(int page, CancelToken cancelToken);

  /// loadMore 的翻页上限：热门排序越往后越冷门，深页换来的多样性和
  /// 把信息流拖没的速度不成比例（与随机推荐的页码窗口同一理由）；最
  /// 新是时间序，但"整页重复自动跳页"在上游无视 page 时会失控（审查
  /// v2 P2-6），两侧同取一个温和上限。
  int get maxLoadMorePages;

  /// 续页游标的起点：第 1 页如果不是搜索源本身（热门的 eapi 快照），
  /// 续页从搜索第 1 页开始；第 1 页就是搜索源（最新的 date 搜索）时
  /// 从第 2 页续。
  int get firstLoadMorePage;

  int _nextPage = 1;
  final Set<String> _seenIds = <String>{};

  /// 会话纪元（审查 v2 P2-5）：build() 重跑（账号/线路切换）时递增，
  /// 在途异步轮次落笔前复核——旧会话的响应不得覆盖新会话的状态。
  int _epoch = 0;

  /// SWR 换新在途（审查 v2 P2-4）：缓存直出后的静默重验期间挡住
  /// loadMore——重验完成整表替换，并发的 loadMore 追加会被丢弃、游
  /// 标复位（重开 app 后下滑 1~2 秒内容跳变的来源）。
  bool _revalidating = false;

  /// 当前 loadMore 轮次的取消令牌（审查 v2 P2-6）：新轮次取消旧轮次，
  /// build() 重跑取消在途轮次——"整页重复自动跳页"的循环不再失控。
  CancelToken? _loadMoreToken;

  @override
  FeedState build() {
    // Notifier 实例在 invalidate 后复用：游标与去重集必须逐字段归位，
    // 否则上一条会话的翻页游标会漏给下一次。纪元递增 + 在途 loadMore
    // 取消：旧会话的轮次落笔前复核不过，直接失效。
    _epoch++;
    _nextPage = 1;
    _seenIds.clear();
    _revalidating = false;
    _loadMoreToken?.cancel();
    _loadMoreToken = null;
    final cached = readCache();
    if (cached != null && cached.isNotEmpty) {
      final books = cached.map((b) => b.toDisplay()).toList();
      _seenIds.addAll(books.map((b) => b.id));
      _nextPage = firstLoadMorePage;
      _revalidating = true;
      unawaited(_loadFirstPage().whenComplete(() => _revalidating = false));
      return FeedState(books: books, hasMore: true);
    }
    unawaited(_loadFirstPage());
    return const FeedState(isLoading: true);
  }

  /// 第 1 页加载（首建 / 下拉刷新共用）。缓存直出的那批会被静默换新，
  /// 换新结果落盘（审查 v2 P2-4：启动缓存不再冻结在首次写入的那批）。
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);
    await _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    final epoch = _epoch;
    try {
      final rawBooks = await fetchInitialPage();
      if (epoch != _epoch) return; // 旧会话的轮次：落笔前复核
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
        unawaited(persistCache(rawBooks));
      } else if (state.books.isEmpty) {
        // 真空：接口成功但没书（新装/源耗尽），空态而不是错误。
        state = state.copyWith(isLoading: false, hasMore: false, error: null);
      } else {
        // 有旧内容但新一轮空了：保旧（别掀掉用户已滚到的信息流）。
        state = state.copyWith(isLoading: false, hasMore: false, error: null);
      }
    } on Object catch (error) {
      if (epoch != _epoch) return;
      if (state.books.isEmpty) {
        state = state.copyWith(isLoading: false, error: error);
      } else {
        // 有旧内容：静默保旧，保持 hasMore，用户还能继续滚/再刷——
        // 静默也记账（审查 v2 P2-2），release 的诊断轨迹里看得到。
        logIgnored('feed_first_page', error);
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// 上滑加载下一页：顺序吃页、按 id 去重，整页重复就自动翻到下一个
  /// 有新书的页；页空 = 源耗尽（hasMore 收口），失败 = 保 hasMore，
  /// 下次滚动原地再试。SWR 换新在途时挡住（新会话整表替换会丢掉并发
  /// 追加）；新轮次取消旧轮次，被取消的旧轮次不落笔。
  Future<void> loadMore() async {
    if (state.isLoading ||
        state.isLoadingMore ||
        _revalidating ||
        !state.hasMore) {
      return;
    }
    _loadMoreToken?.cancel();
    final token = CancelToken();
    _loadMoreToken = token;
    state = state.copyWith(isLoadingMore: true);
    try {
      final added = <DisplayBook>[];
      var page = _nextPage;
      var exhausted = false;
      while (added.isEmpty && page <= maxLoadMorePages) {
        final books = await fetchPage(page, token);
        if (token.isCancelled) return; // 新轮次/新会话接管，别落笔
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
      if (token.isCancelled) return;
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
    } on Object catch (error) {
      if (token.isCancelled) return; // 被取消的旧轮次：新轮次已接管
      // 网络抖动/墙：保持 hasMore 与游标，下次滚动原地再试——静默也
      // 记账（审查 v2 P2-2）。
      logIgnored('feed_load_more', error);
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
  Future<List<Book>?> fetchPage(int page, CancelToken cancelToken) async {
    final response = await ref.read(zlibraryApiProvider).search(
      order: 'popular',
      limit: 50,
      page: page,
      cancelToken: cancelToken,
    );
    if (!response.success) {
      // 抛给 loadMore 的 catch：保 hasMore 原地重试（审查 P2-3）。
      throw StateError(response.error ?? 'Failed to load popular page $page');
    }
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
  Future<List<Book>?> fetchPage(int page, CancelToken cancelToken) async {
    final response = await ref.read(zlibraryApiProvider).search(
      order: 'date',
      limit: 50,
      page: page,
      cancelToken: cancelToken,
    );
    if (!response.success) {
      // 抛给 loadMore 的 catch：保 hasMore 原地重试（审查 P2-3）。
      throw StateError(response.error ?? 'Failed to load recent page $page');
    }
    return response.data ?? [];
  }

  // 时间序本来"自然延续，上限给得宽"（200）——但整页重复自动跳页的
  // 循环在"上游无视 page"时最坏连打 199 个串行请求（审查 v2 P2-6），
  // 与热门侧同取 15：15 页都无新书就该收口，而不是把镜像打成风暴。
  @override
  int get maxLoadMorePages => 15;

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
  /// 会话纪元（审查 v2 P2-5）：开关切换/账号变化重跑 build 时递增，
  /// 在途轮次落笔前复核——切开关的瞬间，旧路的响应不得盖掉新路。
  int _epoch = 0;

  /// 随机流条目上限（审查 v2 P3）：无界累积是内存隐患，300 本 ≈ 六屏
  /// 的余量足够一个会话滑到底。
  static const int _maxHomeFeedBooks = 300;

  @override
  FeedState build() {
    _epoch++;
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
    final epoch = _epoch;
    try {
      final batch = await fetchRandomFeedBatch(
        api: api,
        userId: userId,
        userKey: userKey,
        serveFromCache: false,
      );
      if (epoch != _epoch) return; // 开关/账号已切换：旧路不落笔
      state = FeedState(books: batch, hasMore: batch.isNotEmpty);
    } on Object catch (error) {
      if (epoch != _epoch) return;
      state = FeedState(error: error);
    }
  }

  /// [keepOldOnFailure]：下拉刷新路径置 true——失败时旧内容静默保旧
  /// （别让一次网络抖动掀掉已滚到的流），空流顶错误页给重试（审查
  /// P1-2）。build 直呼路径保持 false：首载失败本就是错误页；而且
  /// build 在途时 element 可能尚未挂载完，catch 里读 `state` 会撞
  /// riverpod 的 requireState（换号失效测试实测），这条路径只能写
  /// 不能读。
  Future<void> _loadPersonalized(
    ZLibraryApi api, {
    bool keepOldOnFailure = false,
  }) async {
    final epoch = _epoch;
    try {
      final response = await api.getUserRecommended();
      if (epoch != _epoch) return; // 开关/账号已切换：旧路不落笔
      if (!response.success) {
        throw StateError(response.error ?? 'Failed to load recommendations');
      }
      state = FeedState(
        books: (response.data ?? []).map((b) => b.toDisplay()).toList(),
        hasMore: false,
      );
    } on Object catch (error) {
      if (epoch != _epoch) return;
      if (!keepOldOnFailure) {
        state = FeedState(error: error);
        return;
      }
      state = state.books.isEmpty
          ? FeedState(error: error)
          : state.copyWith(isLoading: false);
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
        await _loadPersonalized(api, keepOldOnFailure: true);
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
  /// 抽不出新书就收口（疲劳名单循环回来了）。条目到上限就收口
  /// （审查 v2 P3：随机流无界累积）。
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    final useRandom = ref.read(randomRecommendProvider);
    if (!useRandom) return; // 个性化单批，无更多
    if (state.books.length >= _maxHomeFeedBooks) {
      state = state.copyWith(isLoadingMore: false, hasMore: false);
      return;
    }
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
    } on Object catch (error) {
      // 抖动/墙：保持 hasMore，下次滚动原地再试——静默也记账
      // （审查 v2 P2-2）。
      logIgnored('feed_home_load_more', error);
      state = state.copyWith(isLoadingMore: false);
    }
  }
}

final homeFeedProvider = NotifierProvider<HomeFeedController, FeedState>(
  HomeFeedController.new,
);
