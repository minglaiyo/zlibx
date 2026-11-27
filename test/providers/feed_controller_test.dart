import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/feed_controller.dart';
import 'package:zlibx/providers/home_feed_provider.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/home_feed_page_cache.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/random_feed_cache.dart';

/// 三个信息流控制器（2026-11-20 改版）：启动缓存直出 + 后台换新（SWR）、
/// 上滑逐页累积、按 id 去重、页空/失败各有归宿。热门第 1 页走
/// getMostPopular 快照、续页走 popular 排序搜索；最新全程 date 排序
/// 搜索；首页随机批走 [fetchRandomFeedBatch]。
Directory? _hiveDir;

Book _book(int id) => Book(id: id, title: '书$id');

class _SignedInAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
    isLoading: false,
    user: const User(
      id: 'acct-1',
      email: 'a@example.com',
      name: 'a',
      remixUserkey: 'key-1',
    ),
  );
}

class _FixedRandomRecommend extends RandomRecommendNotifier {
  _FixedRandomRecommend(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

/// 假接口：快照、popular/date 排序搜索分页、个性化推荐、随机分类页
/// 全部可配，按序记账。
class _FakeFeedApi implements ZLibraryApi {
  /// getMostPopular 快照返回（第 1 页直抓的源）。
  List<Book> snapshot = [_book(1), _book(2)];

  /// search(order → page → books)；缺页 = 空列表。
  final Map<String, Map<int, List<Book>>> searchPages = {};

  /// 随机分类页：每页给 50 本，id 从 [randomSeedId] 起每次 +1 递增
  /// （调用次数驱动，保证每批不重）。
  int randomSeedId = 900000;

  List<Book> personalized = const [];

  /// 置 true 时 getUserRecommended 返回 fail（审查 P1-2 回归用）。
  bool recommendedFail = false;

  /// 这些 date 搜索页返回 fail（审查 P2-3 回归用：续页失败不得折叠
  /// 成"源耗尽"）。
  final Set<int> failingDatePages = {};

  int snapshotCalls = 0;
  int searchPopularCalls = 0;
  int searchDateCalls = 0;
  int recommendedCalls = 0;
  int categoryCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<List<Book>>> getMostPopular({int? page}) async {
    snapshotCalls++;
    return ApiResponse.ok(snapshot);
  }

  @override
  Future<ApiResponse<List<Book>>> search({
    String? message,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int? page,
    int? limit,
    bool? exact,
    CancelToken? cancelToken,
  }) async {
    final key = order ?? '';
    if (key == 'popular') searchPopularCalls++;
    if (key == 'date') searchDateCalls++;
    if (key == 'date' && failingDatePages.contains(page ?? 1)) {
      return ApiResponse.fail('date page failed');
    }
    final books = searchPages[key]?[page ?? 1] ?? const <Book>[];
    return ApiResponse.ok(books);
  }

  @override
  Future<ApiResponse<List<Book>>> getUserRecommended() async {
    recommendedCalls++;
    if (recommendedFail) return ApiResponse.fail('recommended failed');
    return ApiResponse.ok(personalized);
  }

  @override
  Future<ApiResponse<CategoryPage>> getCategoryBooks(
    int categoryId, {
    int page = 1,
    String? order,
    CancelToken? cancelToken,
  }) async {
    categoryCalls++;
    return ApiResponse.ok(
      CategoryPage(
        books: [
          for (var i = 0; i < 50; i++)
            CategoryBook(book: _book(randomSeedId++)),
        ],
        totalPages: 500,
      ),
    );
  }
}

ProviderContainer _container(
  _FakeFeedApi api, {
  bool? randomRecommend,
}) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(_SignedInAuth.new),
      if (randomRecommend != null)
        randomRecommendProvider.overrideWith(
          () => _FixedRandomRecommend(randomRecommend),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 等控制器把后台首屏/落盘跑完：假接口全是即时 async，两轮事件循环
/// 足够。
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

List<String> _ids(FeedState state) => state.books.map((b) => b.id).toList();

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('feed_controller');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  setUp(() async {
    await HomeFeedPageCache.clearAll();
    await RandomFeedCache.clearAll();
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir?.delete(recursive: true);
  });

  group('热门信息流', () {
    test('无缓存：现抓快照并落盘', () async {
      final api = _FakeFeedApi();
      final container = _container(api);
      container.read(popularFeedProvider);
      await _settle();

      final state = container.read(popularFeedProvider);
      expect(_ids(state), ['1', '2']);
      expect(api.snapshotCalls, 1);
      expect(
        HomeFeedPageCache.popular()!.map((b) => b.id.toString()).toList(),
        ['1', '2'],
      );
    });

    test('有缓存：首建同步直出缓存，后台换新', () async {
      // 上一会话留下的缓存。
      await HomeFeedPageCache.savePopular([_book(77), _book(78)]);

      final api = _FakeFeedApi();
      final container = _container(api);
      // SWR 的保证是"第一帧就画缓存"：build 同步返回缓存那批，重验
      // 在后台跑——首页不转圈，而不是字面意义的零请求。
      final first = container.read(popularFeedProvider);
      expect(_ids(first), ['77', '78']);

      await _settle();
      final state = container.read(popularFeedProvider);
      // 后台换新：快照那批替换缓存那批。
      expect(_ids(state), ['1', '2']);
      expect(api.snapshotCalls, 1);
    });

    test('loadMore：追加 popular 搜索续页，快照与搜索重叠的 id 去重', () async {
      final api = _FakeFeedApi()
        ..snapshot = [_book(1)]
        ..searchPages['popular'] = {
          // page 1 整页与快照重复：loadMore 应跳过它直接吃 page 2。
          1: [_book(1)],
          2: [_book(3), _book(4)],
        };
      final container = _container(api);
      container.read(popularFeedProvider);
      await _settle();
      expect(_ids(container.read(popularFeedProvider)), ['1']);

      await container.read(popularFeedProvider.notifier).loadMore();
      final state = container.read(popularFeedProvider);
      expect(_ids(state), ['1', '3', '4']);
      expect(state.hasMore, isTrue);
      // page 1 被整页跳过：搜索调用只有一次（page 2）……不，跳页也要
      // 先抓 page 1 判重，两次都对。
      expect(api.searchPopularCalls, 2);
    });

    test('loadMore：页空就收口（hasMore=false）', () async {
      final api = _FakeFeedApi()
        ..snapshot = [_book(1)]
        ..searchPages['popular'] = {1: [_book(2)]};
      final container = _container(api);
      container.read(popularFeedProvider);
      await _settle();

      // 第一次 loadMore 吃到第 1 页的新书；第二次页空，收口。
      await container.read(popularFeedProvider.notifier).loadMore();
      expect(_ids(container.read(popularFeedProvider)), ['1', '2']);
      expect(container.read(popularFeedProvider).hasMore, isTrue);

      await container.read(popularFeedProvider.notifier).loadMore();
      expect(_ids(container.read(popularFeedProvider)), ['1', '2']);
      expect(container.read(popularFeedProvider).hasMore, isFalse);

      // 收口后再滚也不再发请求。
      final calls2 = api.searchPopularCalls;
      await container.read(popularFeedProvider.notifier).loadMore();
      expect(api.searchPopularCalls, calls2);
    });

    test('refresh：重置为新快照', () async {
      final api = _FakeFeedApi();
      final container = _container(api);
      container.read(popularFeedProvider);
      await _settle();

      api.snapshot = [_book(9)];
      await container.read(popularFeedProvider.notifier).refresh();
      await _settle();
      expect(_ids(container.read(popularFeedProvider)), ['9']);
    });

    test('refresh 返回空页时保留旧内容和分页能力', () async {
      final api = _FakeFeedApi();
      final container = _container(api);
      container.read(popularFeedProvider);
      await _settle();
      expect(_ids(container.read(popularFeedProvider)), ['1', '2']);

      api.snapshot = const [];
      await container.read(popularFeedProvider.notifier).refresh();
      var state = container.read(popularFeedProvider);
      expect(_ids(state), ['1', '2']);
      expect(state.hasMore, isTrue);

      api.searchPages['popular'] = {
        1: [_book(3)],
      };
      await container.read(popularFeedProvider.notifier).loadMore();
      state = container.read(popularFeedProvider);
      expect(_ids(state), ['1', '2', '3']);
    });
  });

  group('最新信息流', () {
    test('无缓存：date 搜索第 1 页直抓并落盘；loadMore 累积第 2 页', () async {
      final api = _FakeFeedApi()
        ..searchPages['date'] = {
          1: [_book(1), _book(2)],
          2: [_book(3), _book(4)],
        };
      final container = _container(api);
      container.read(recentFeedProvider);
      await _settle();

      final state = container.read(recentFeedProvider);
      expect(_ids(state), ['1', '2']);
      expect(api.searchDateCalls, 1);
      expect(
        HomeFeedPageCache.recent()!.map((b) => b.id.toString()).toList(),
        ['1', '2'],
      );

      await container.read(recentFeedProvider.notifier).loadMore();
      expect(_ids(container.read(recentFeedProvider)), ['1', '2', '3', '4']);
      expect(api.searchDateCalls, 2);
    });

    test('续页接口失败保 hasMore 原地重试，不折叠成耗尽（P2-3 回归）', () async {
      final api = _FakeFeedApi()
        ..searchPages['date'] = {
          1: [_book(1)],
        }
        ..failingDatePages.add(2);
      final container = _container(api);
      container.read(recentFeedProvider);
      await _settle();
      expect(_ids(container.read(recentFeedProvider)), ['1']);

      // page 2 失败：保持 hasMore 与游标，不收口——修复前
      // success:false 折叠成 null 被当成"源耗尽"，hasMore 永久 false，
      // 之后滚到底也没反应。
      await container.read(recentFeedProvider.notifier).loadMore();
      var state = container.read(recentFeedProvider);
      expect(_ids(state), ['1']);
      expect(state.hasMore, isTrue);
      expect(state.isLoadingMore, isFalse);

      // 恢复后原地重试同一页：追加成功，流继续。
      api.failingDatePages.clear();
      api.searchPages['date']![2] = [_book(3)];
      await container.read(recentFeedProvider.notifier).loadMore();
      state = container.read(recentFeedProvider);
      expect(_ids(state), ['1', '3']);
      expect(state.hasMore, isTrue);
    });

    test('有缓存：首建同步直出缓存，后台换新', () async {
      await HomeFeedPageCache.saveRecent([_book(5)]);

      final api = _FakeFeedApi()
        ..searchPages['date'] = {1: [_book(1)]};
      final container = _container(api);
      final first = container.read(recentFeedProvider);
      expect(_ids(first), ['5']);

      await _settle();
      expect(_ids(container.read(recentFeedProvider)), ['1']);
      expect(api.searchDateCalls, 1);
    });
  });

  group('首页推荐信息流', () {
    test('随机开：loadMore 逐批累积且批间不重书', () async {
      final api = _FakeFeedApi();
      final container = _container(api, randomRecommend: true);
      container.read(homeFeedProvider);
      await _settle();
      final first = container.read(homeFeedProvider);
      expect(first.books, hasLength(50));

      await container.read(homeFeedProvider.notifier).loadMore();
      final second = container.read(homeFeedProvider);
      expect(second.books.length, 100);
      // 新追加的那段与首屏批不重书（疲劳名单 + 去重双保险）。注意
      // 信息流是累积的，second ⊇ first，直接拿全量求交集必然等于
      // first 本身，比的是新增段。
      final appended = second.books.skip(first.books.length).toList();
      expect(
        appended.map((b) => b.id).toSet().intersection(
          first.books.map((b) => b.id).toSet(),
        ),
        isEmpty,
      );
    });

    test('随机开：refresh 换一批新的替换整条流', () async {
      final api = _FakeFeedApi();
      final container = _container(api, randomRecommend: true);
      container.read(homeFeedProvider);
      await _settle();
      // 先 loadMore 到 100 本，刷新必须重置回一批 50 本，而不是在
      // 累积流上继续叠。
      await container.read(homeFeedProvider.notifier).loadMore();
      expect(container.read(homeFeedProvider).books, hasLength(100));

      await container.read(homeFeedProvider.notifier).refresh();
      expect(container.read(homeFeedProvider).books, hasLength(50));
    });

    test('个性化（开关关）：单批展示，hasMore=false，loadMore 无请求', () async {
      final api = _FakeFeedApi()..personalized = [_book(1), _book(2)];
      final container = _container(api, randomRecommend: false);
      container.read(homeFeedProvider);
      await _settle();

      final state = container.read(homeFeedProvider);
      expect(_ids(state), ['1', '2']);
      expect(state.hasMore, isFalse);
      expect(api.recommendedCalls, 1);

      await container.read(homeFeedProvider.notifier).loadMore();
      expect(_ids(container.read(homeFeedProvider)), ['1', '2']);
      expect(api.recommendedCalls, 1);
    });

    test('个性化首载失败：错误页而不是空态（P1-2 回归）', () async {
      final api = _FakeFeedApi()..recommendedFail = true;
      final container = _container(api, randomRecommend: false);
      container.read(homeFeedProvider);
      await _settle();

      final state = container.read(homeFeedProvider);
      expect(state.books, isEmpty);
      // error != null 才会走到 UI 的错误分支给重试按钮；否则是"无书"。
      expect(state.error, isNotNull);
      expect(state.isLoading, isFalse);
    });

    test('个性化刷新失败：有旧内容保旧不出错；空流顶错误页（P1-2 回归）', () async {
      final api = _FakeFeedApi()..personalized = [_book(1), _book(2)];
      final container = _container(api, randomRecommend: false);
      container.read(homeFeedProvider);
      await _settle();
      expect(_ids(container.read(homeFeedProvider)), ['1', '2']);

      // 有旧内容：一次网络抖动不能掀掉已滚到的流，也不该报错页。
      api.recommendedFail = true;
      await container.read(homeFeedProvider.notifier).refresh();
      var state = container.read(homeFeedProvider);
      expect(_ids(state), ['1', '2']);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);

      // 空流：失败必须顶错误页（重试入口），而不是"无书"空态——
      // 修复前 refresh 收尾的 copyWith 会把 error 抹掉，正好掉进空态。
      api.recommendedFail = false;
      api.personalized = const [];
      await container.read(homeFeedProvider.notifier).refresh();
      expect(_ids(container.read(homeFeedProvider)), isEmpty);

      api.recommendedFail = true;
      await container.read(homeFeedProvider.notifier).refresh();
      state = container.read(homeFeedProvider);
      expect(state.error, isNotNull);
      expect(state.isLoading, isFalse);
      expect(state.books, isEmpty);
    });
  });
}
