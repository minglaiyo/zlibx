import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/feed_controller.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/home/widgets/home_book_grid.dart';
import 'package:zlibx/widgets/book_card.dart';

/// 首页网格在下拉刷新上的行为：数据 / 空 / 加载 / 错误四种信息流状态
/// （[FeedState]，2026-11-20 从 AsyncValue 换过来），每一种都必须能靠
/// 下拉手势触发 onRefresh。
///
/// 2026-11-15 去掉个性化推荐的热门兜底之后，接口一失败首页就停在错误态、
/// 返回空列表就停在空态。改动前这两档（还有加载态）只是一个 Padding：
/// 既没有下拉层，也没有能越界滚动的子组件——手势落不到滚动视图上，拉
/// 多少次都不会重新拉取，错误态又没有重试按钮，首页等于关死在错误页上。
/// 这条测试守的就是"每一档都拉得动"，因为它出问题时整站照跑，只有真机
/// 下拉才看得出来。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  /// 列数设置默认走 Hive 同步读；测试里不初始化 Hive，直接给默认那一档
  /// （自适应关掉 = 旧版排布）。
  @override
  bool build() => false;
}

List<DisplayBook> _books(int n) => [
  for (var i = 1; i <= n; i++)
    DisplayBook(
      id: 'grid-$i',
      title: 'Synthetic Rec $i',
      author: 'Author $i',
      tag: 'PDF',
      tagExtra: '2021',
      meta: '1.02 MB',
      source: BookSource.zlibrary,
      cover: 'https://example.invalid/covers/$i.jpg',
    ),
];

int _refreshes = 0;

Future<void> _pump(WidgetTester tester, FeedState feed) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adaptiveGridProvider.overrideWith(_NoHiveAdaptive.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: HomeBookGrid(
            feed: feed,
            // 与 HomeTab 一致：悬浮毛玻璃头部的高度在滚动区里预留出来。
            topPadding: 200,
            scrollController: ScrollController(),
            onRefresh: () async {
              _refreshes++;
            },
            onLoadMore: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 顶部下拉：松手时 RefreshIndicator 要能进入 armed 才会调 onRefresh。
/// armed 的门槛是"越界拉出的距离 / (视口高 * 0.25) 让指示器颜色走到
/// 全不透明"，即 1/1.5 —— 1600 高的测试视口要拉够 ~267px，这里给 420
/// 留足余量（低于这个距离的"轻拉"本来就不该刷新，是设计如此）。
/// 用显式 pump 而不是 pumpAndSettle：加载态的指示器是无限动画。
Future<void> _pullDown(WidgetTester tester) async {
  await tester.drag(find.byType(RefreshIndicator), const Offset(0, 420));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  setUp(() => _refreshes = 0);

  testWidgets('数据态：下拉触发刷新，且只有一层下拉指示器', (tester) async {
    await _pump(tester, FeedState(books: _books(8), hasMore: false));
    expect(find.byType(BookCard), findsNWidgets(8));
    expect(find.byType(RefreshIndicator), findsNWidgets(1));
    await _pullDown(tester);
    expect(_refreshes, 1);
  });

  testWidgets('空态：下拉触发刷新', (tester) async {
    await _pump(tester, const FeedState(books: [], isLoading: false));
    expect(find.byType(BookCard), findsNothing);
    await _pullDown(tester);
    expect(_refreshes, 1);
  });

  testWidgets('加载态：下拉触发刷新', (tester) async {
    await _pump(tester, const FeedState(isLoading: true));
    await _pullDown(tester);
    expect(_refreshes, 1);
  });

  testWidgets('错误态：下拉触发刷新', (tester) async {
    await _pump(
      tester,
      FeedState(error: StateError('synthetic boom')),
    );
    expect(find.byType(BookCard), findsNothing);
    await _pullDown(tester);
    expect(_refreshes, 1);
  });

  testWidgets('错误态：带重试按钮，点它同样重新拉一次', (tester) async {
    await _pump(
      tester,
      FeedState(error: StateError('synthetic boom')),
    );
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_refreshes, 1);
  });
}
