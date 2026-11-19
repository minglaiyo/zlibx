import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/recommended_booklists_provider.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/account/booklists_screen.dart';
import 'package:zlibx/widgets/booklist_tile.dart';

/// 毛玻璃开关默认走 Hive 同步读;测试里不开 Hive,固定给默认档(开)。
class _FixedBlur extends BlurNotifier {
  @override
  bool build() => true;
}

/// 书单主页(2026-11-19 整体重设计,视觉稿 ①)的渲染契约:发现 tab
/// 的 seed 数据必须画成横向封面流——每张书单一张 BooklistCoverCard、
/// 名称与册数文字齐全,不许出现空白区(旧版"网格切换白屏"bug 的
/// 现代对应:新结构里封面流缺席/残缺都算回归)。
///
/// 两个被 watch 的 controller 都用 fake 覆盖:ready 的 discover 态 +
/// 空推荐位;所有 controller 调用 no-op,网络与 WebView 永不触发。
List<Booklist> _fakeDiscoverLists() => [
  for (var i = 1; i <= 10; i++)
    Booklist(
      id: '9000$i',
      name: 'Synthetic List $i',
      author: 'Synthetic Author',
      count: 2 + i,
      color: -1,
      coverUrl: 'https://example.invalid/covers/$i.jpg',
      url: 'https://example.invalid/booklist/9000$i',
    ),
];

class _FakeBooklistsController extends BooklistsController {
  BooklistTab? lastSetTab;

  @override
  BooklistsState build() => BooklistsState(
    tab: BooklistTab.discover,
    phase: BooklistsPhase.ready,
    lists: _fakeDiscoverLists(),
    order: 'popular',
    nextPage: 2,
    hasMore: true,
  );

  @override
  Future<void> loadFirst() async {}

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> refresh() async {}

  @override
  void search(String query) {}

  @override
  void setOrder(String order) {}

  @override
  void setTab(BooklistTab tab) {
    lastSetTab = tab;
  }
}

class _FakeRecommendedBooklistsController
    extends RecommendedBooklistsController {
  @override
  RecommendedBooklistsState build() =>
      const RecommendedBooklistsState(isLoading: false, lists: []);
}

Future<_FakeBooklistsController> _pumpScreen(WidgetTester tester) async {
  final fake = _FakeBooklistsController();
  await tester.binding.setSurfaceSize(const Size(800, 3200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        booklistsControllerProvider.overrideWith(() => fake),
        recommendedBooklistsProvider.overrideWith(
          _FakeRecommendedBooklistsController.new,
        ),
        blurEnabledProvider.overrideWith(_FixedBlur.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const BooklistsScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
  return fake;
}

void main() {
  testWidgets('discover tab 把 seed 数据画成横向封面流', (tester) async {
    await _pumpScreen(tester);

    // 封面卡至少铺满首屏视口;名称与「作者 · 册数」meta 行齐全。
    expect(find.byType(BooklistCoverCard), findsWidgets);
    expect(find.text('Synthetic List 1'), findsOneWidget);
    expect(find.text('Synthetic Author · 3 books'), findsOneWidget);
    // 排字 tab:三项都在("我的书单"只在 tab 行——五轮定稿后 AppBar
    // 整个退役,标题文字不再单独出现)。
    expect(find.text('My Booklists'), findsOneWidget);
    expect(find.text('Discover Booklists'), findsOneWidget);
    expect(find.text('Favorited booklists'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('视图切换按钮随封面流退役;排序行保留', (tester) async {
    await _pumpScreen(tester);

    expect(find.byIcon(Icons.grid_view_rounded), findsNothing);
    expect(find.byIcon(Icons.view_list_rounded), findsNothing);
    expect(find.byIcon(Icons.swap_vert_rounded), findsOneWidget);
  });

  testWidgets('左右滑动切板块:板块序 我的/收藏/发现,从发现右滑回收藏',
      (tester) async {
    final fake = await _pumpScreen(tester);

    // 新板块序里 discover 是最后一页;向右甩 = 上一页(收藏)。
    // 起点用 PageView 中心偏下,避开边缘卡片的热区。
    await tester.flingFrom(
      tester.getCenter(find.byType(PageView)) + const Offset(0, 120),
      const Offset(350, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(fake.lastSetTab, BooklistTab.favorite);
    expect(tester.takeException(), isNull);
  });
}
