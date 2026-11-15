import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/book_categories.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/home_feed_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/random_feed_history.dart';

/// 首页随机推荐的抽样规则（2026-11-15 改）：分类两级抽、页码只在窗口
/// 里抽、最近看过的与收藏的都要跳过。
///
/// 三条各自守一个具体的毛病：
/// - 均匀抽 841 个分类 = 子类多的门类被按比例压过来，"随机"其实是几
///   个大门类（下面的分布数字就是它的量化对比）；
/// - 页码在整个总页数范围里抽 = 大类门几千页，几乎必然抽到深页，每往
///   深一页就多一次分类 HTML 请求（被墙时每次都可能落到 WebView solver）；
/// - 不去重 = 同一本书几次刷新反复出现，而首页一次只要 50 本。
///
/// 抽样随机源是注入的（[setRandomFeedRandomForTest]），所以分布与批
/// 次内容都可复现——这条测试不能靠"跑很多次碰运气"。
Directory? _hiveDir;

/// 同种子必然同序列：Dart 的 Random 是确定性的，测试据此断言精确值。
const _seed = 20261115;

/// 让 40 次刷新里必定抽到窗口末端那一页的种子（补页那条路的覆盖）。
const _edgeSeed = 7;

Book _book(int id) => Book(id: id, title: '书$id');

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('random_feed_sampling');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  setUp(() async {
    resetRandomFeedStateForTest();
    await RandomFeedHistory.clear();
  });

  tearDown(() => resetRandomFeedStateForTest());

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir?.delete(recursive: true);
  });

  group('分类两级抽样', () {
    test('同一种子的序列可复现，且抽出的都是真分类', () {
      final all = kBookCategoryParents.keys.toSet();
      final first = pickSequence(5, Random(_seed));
      expect(pickSequence(5, Random(_seed)), first);
      for (final id in pickSequence(500, Random(_seed))) {
        expect(all, contains(id));
      }
    });

    test('门类那一层被拉平：每个一级门类都抽得到', () {
      final tops = kBookCategoryParents.entries
          .where((e) => e.value == null)
          .map((e) => e.key)
          .toSet();
      final byFamily = <int, int>{};
      const draws = 4000;
      final random = Random(_seed);
      for (var i = 0; i < draws; i++) {
        final categoryId = pickRandomCategoryId(random);
        final family = kBookCategoryParents[categoryId] ?? categoryId;
        byFamily[family] = (byFamily[family] ?? 0) + 1;
      }
      // 39 个门类、4000 次：每类期望 ~102。
      expect(byFamily.length, tops.length);
      final counts = byFamily.values.toList()..sort();
      expect(counts.first, greaterThan(40));
      // 两级抽样的门间差距只在抽样噪声里；均匀抽 841 时它由子类数
      // 决定，大类门能把小类门压到十几倍开外。
      expect(counts.last / counts.first, lessThan(4.0));
      final flatSpread = _flatFamilySpread();
      expect(flatSpread, greaterThan(counts.last / counts.first));
    });
  });

  group('页码窗口', () {
    test('总页数上千也只在窗口里抽，且窗口内每个页码都抽得到', () {
      final random = Random(_seed);
      final seen = <int>{};
      for (var i = 0; i < 3000; i++) {
        final page = pickRandomPage(random, 5000);
        expect(page, inInclusiveRange(1, kRandomPageWindow));
        seen.add(page);
      }
      expect(seen.length, kRandomPageWindow);
    });

    test('页数不足窗口时按真实页数收，页数缺失时退回第 1 页', () {
      final random = Random(_seed);
      for (var i = 0; i < 500; i++) {
        expect(pickRandomPage(random, 7), inInclusiveRange(1, 7));
      }
      expect(pickRandomPage(random, 1), 1);
      expect(pickRandomPage(random, 0), 1);
    });
  });

  group('去重补齐', () {
    test('先取没看过的，凑不满再用看过的补——永远不补空', () {
      final books = [for (var i = 1; i <= 8; i++) _book(i)];
      final excluded = {'1', '2', '3', '4', '5', '6'};
      // 只剩 2 本没看过，仍然凑满 5 本：其余从看过的里补。
      final picked = pickUnseen(books, excluded, 5);
      expect(picked.length, 5);
      expect(picked.map((b) => b.id).take(2), [7, 8]);
      expect(picked.map((b) => b.id).skip(2), containsAll(<int>[1, 2, 3]));
    });

    test('没看过的够一批时一本旧的都不掺', () {
      final books = [for (var i = 1; i <= 60; i++) _book(i)];
      final picked = pickUnseen(books, {'1', '2'}, 50);
      expect(picked.length, 50);
      expect(picked.map((b) => b.id), isNot(contains(1)));
      expect(picked.map((b) => b.id), isNot(contains(2)));
    });

    test('抽到的页本身是空的才返回空（换分类重试的信号）', () {
      expect(pickUnseen(<Book>[], {'1'}, 50), isEmpty);
    });
  });

  group('要跳过的集合', () {
    test('疲劳名单 + 当前账号收藏，未登录时只有疲劳名单', () async {
      RandomFeedHistory.recordShown(['11', '12']);
      await HiveService.settingsBox.put('favorite_books_acct-1', <String>[
        '21',
      ]);
      await HiveService.settingsBox.put('favorite_books_acct-2', <String>[
        '31',
      ]);
      expect(excludedBookIdsFor('acct-1'), {'11', '12', '21'});
      // 别的账号的收藏不算数。
      expect(excludedBookIdsFor('acct-2'), {'11', '12', '31'});
      expect(excludedBookIdsFor(null), {'11', '12'});
    });
  });

  group('首页随机推荐（走假的分类接口）', () {
    test('每次 50 本、页码都在窗口内，且几批之间不重书', () async {
      final api = _FakeCategoryApi(totalPages: 5000);
      final container = _container(api);
      setRandomFeedRandomForTest(Random(_seed));

      final batches = <List<DisplayBook>>[];
      for (var i = 0; i < 6; i++) {
        batches.add(await container.read(randomBooksProvider.future));
        container.invalidate(randomBooksProvider);
      }

      for (final batch in batches) {
        expect(batch.length, 50);
      }
      // 深页一次都不该出现：旧写法在 1..5000 里均匀抽，几乎必然越界。
      expect(api.requests.every((r) => r.page <= kRandomPageWindow), isTrue);
      expect(api.requests.every((r) => r.page >= 1), isTrue);
      for (var i = 0; i < batches.length; i++) {
        for (var j = i + 1; j < batches.length; j++) {
          final overlap = batches[i]
              .map((b) => b.id)
              .toSet()
              .intersection(batches[j].map((b) => b.id).toSet());
          expect(overlap, isEmpty, reason: '第 ${i + 1} 批与第 ${j + 1} 批撞书');
        }
      }
    });

    test('展示过的一本不漏地进名单（预取那批不算）', () async {
      final api = _FakeCategoryApi(totalPages: 500);
      final container = _container(api);
      setRandomFeedRandomForTest(Random(_seed));

      final batch = await container.read(randomBooksProvider.future);
      expect(RandomFeedHistory.readSync(), batch.map((b) => b.id).toList());
      await RandomFeedHistory.flush();
      expect(
        HiveService.settingsBox.get(RandomFeedHistory.boxKey),
        batch.map((b) => b.id).toList(),
      );
    });

    test('预取的那批不记账：只有真展示过的进名单', () async {
      final container = _container(_FakeCategoryApi(totalPages: 500));
      setRandomFeedRandomForTest(Random(_seed));
      final first = await container.read(randomBooksProvider.future);
      // 让后台预取跑完（假接口全程同步，转两次事件循环足够）。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 预取那批只是备着，用户还没刷到它——提前记账会把没露过面的
      // 书算成看过的，白堵后面的抽样（账号一换这批还整个作废）。
      expect(RandomFeedHistory.readSync().length, 50);
      expect(RandomFeedHistory.readSync(), first.map((b) => b.id).toList());
    });

    test('抽到窗口末端时，补页也不越界', () async {
      // 每页只给 5 本，所以每次刷新都要"顺取下一页补满"——补页这条
      // 路才有请求可测。窗口末端那页必须真被抽到（下面的 expect 就是
      // 这件事），否则"补页跑出窗口"这个毛病根本测不出来。
      final api = _FakeCategoryApi(totalPages: 5000, pageSize: 5);
      final container = _container(api);
      setRandomFeedRandomForTest(Random(_edgeSeed));
      for (var i = 0; i < 40; i++) {
        await container.read(randomBooksProvider.future);
        container.invalidate(randomBooksProvider);
      }
      final pages = api.requests.map((r) => r.page).toSet();
      expect(pages, contains(kRandomPageWindow));
      expect(
        pages.where((p) => p < 1 || p > kRandomPageWindow),
        isEmpty,
        reason: '补页跑到了窗口外：$pages',
      );
    });

    test('整页池都看过时照样出满 50 本：去重永远不把首页抽空', () async {
      // 假接口每页都给同一批书 id，于是第二批起整页都在名单里——
      // 这正是"分类翻完、没什么新可看"的极端情形，此时必须补旧的，
      // 而不是给首页一个空列表（空列表会显示成"没有找到书"）。
      final container = _container(
        _FakeCategoryApi(totalPages: 500, fixedPool: true),
      );
      setRandomFeedRandomForTest(Random(_seed));
      final first = await container.read(randomBooksProvider.future);
      container.invalidate(randomBooksProvider);

      final second = await container.read(randomBooksProvider.future);
      expect(first.map((b) => b.id).toSet(), second.map((b) => b.id).toSet());
      expect(second.length, 50);
    });
  });
}

/// 均匀抽 841 个分类时，门类之间的期望差距（旧写法的量化对比）。
/// 门类概率 = (1 + 子类数) / 841，所以差距就是子类数的差距。
double _flatFamilySpread() {
  final size = <int, int>{};
  for (final entry in kBookCategoryParents.entries) {
    final family = entry.value ?? entry.key;
    size[family] = (size[family] ?? 0) + 1;
  }
  final sizes = size.values.toList()..sort();
  return sizes.last / sizes.first;
}

/// 连续抽 [count] 个分类 id（测试里验证"都是真分类"用）。
List<int> pickSequence(int count, Random random) => [
  for (var i = 0; i < count; i++) pickRandomCategoryId(random),
];

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

/// 假分类接口：一页 50 本，书 id = 分类*100000 + 页*100 + 序号，
/// 所以"撞书"只可能来自抽样本身；每次请求都记下来。
class _FakeCategoryApi implements ZLibraryApi {
  _FakeCategoryApi({
    required this.totalPages,
    this.fixedPool = false,
    this.pageSize = 50,
  });

  final int totalPages;

  /// 每页给几本：小于 50 时每次刷新都会走到"顺取下一页补满"那条路。
  final int pageSize;

  /// 每页都给同一批书 id（模拟"这个分类的书全看过"）。
  final bool fixedPool;
  final List<({int categoryId, int page})> requests = [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<CategoryPage>> getCategoryBooks(
    int categoryId, {
    int page = 1,
    String? order,
  }) async {
    requests.add((categoryId: categoryId, page: page));
    return ApiResponse.ok(
      CategoryPage(
        books: [
          for (var i = 0; i < pageSize; i++)
            CategoryBook(
              book: _book(
                fixedPool ? 900000 + i : categoryId * 100000 + page * 100 + i,
              ),
            ),
        ],
        totalPages: totalPages,
      ),
    );
  }
}

ProviderContainer _container(_FakeCategoryApi api) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(_SignedInAuth.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}
