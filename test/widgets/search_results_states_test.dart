// P2-6: 搜索结果区的四态分支。
//
// 注意分工:四态(未搜/加载/错误/无结果)不在 SearchResultsView 里,
// 它只画结果头 + 列表/网格;分支梯在 SearchBodyView(build 里按
// showResults/isQueryEmpty/hasSearched/isLoading/loginRequired/
// error 的顺序走)。这里按真实分支测 SearchBodyView,结果态则走
// showResults=true 那条路进 SearchResultsView,不断言它没有的状态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/screens/search/widgets/search_body_view.dart';
import 'package:zlibx/screens/search/widgets/search_skeleton_grid.dart';

DisplayBook _book(String id, String title) => DisplayBook(
  id: id,
  title: title,
  author: '作者 $id',
  source: BookSource.zlibrary,
);

void main() {
  Future<void> pumpBody(
    WidgetTester tester, {
    bool showResults = false,
    bool isQueryEmpty = false,
    bool categoryPicked = false,
    bool hasSearched = true,
    bool isLoading = false,
    bool isLoadingMore = false,
    bool loginRequired = false,
    String? error,
    int resultCount = 0,
    List<DisplayBook> books = const [],
    bool isListView = true,
    VoidCallback? onRetrySearch,
    VoidCallback? onRetryLoadMore,
    VoidCallback? onOpenLogin,
    ValueChanged<DisplayBook>? onOpenBook,
  }) async {
    final listView = ValueNotifier<bool>(isListView);
    addTearDown(listView.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context)!;
            return Scaffold(
              body: SearchBodyView(
                l10n: l10n,
                adaptiveGridColumns: false,
                isQueryEmpty: isQueryEmpty,
                categoryPicked: categoryPicked,
                hasSearched: hasSearched,
                isLoading: isLoading,
                isLoadingMore: isLoadingMore,
                loginRequired: loginRequired,
                error: error,
                resultCount: resultCount,
                showResults: showResults,
                isListViewListenable: listView,
                onToggleView: () {},
                onScrollNotification: (_) => false,
                currentPage: 1,
                totalPagesText: '3',
                isFullTextMode: false,
                isArticleMode: false,
                books: books,
                hits: const [],
                articles: const [],
                recentSearches: const [],
                onSearchAgain: (_) {},
                onRemoveRecentSearch: (_) {},
                onClearRecentSearches: () {},
                onOpenBook: onOpenBook ?? (_) {},
                onOpenFullTextHit: (_) {},
                onOpenArticle: (_) {},
                onRetryLoadMore: onRetryLoadMore ?? () {},
                onRetrySearch: onRetrySearch ?? () {},
                onOpenLogin: onOpenLogin ?? () {},
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('未搜过显示开始搜索提示', (tester) async {
    await pumpBody(tester, hasSearched: false);

    expect(find.text('开始搜索'), findsOneWidget);
    expect(find.text('输入书名、作者或关键词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载态显示骨架屏', (tester) async {
    await pumpBody(tester, isLoading: true);

    expect(find.byType(SearchSkeletonGrid), findsOneWidget);
    expect(find.text('开始搜索'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全文登录态显示登录入口,点按回调', (tester) async {
    var openedLogin = false;
    await pumpBody(
      tester,
      loginRequired: true,
      onOpenLogin: () => openedLogin = true,
    );

    expect(find.text('请先登录后使用全文检索'), findsOneWidget);
    await tester.tap(find.text('登录'));
    expect(openedLogin, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误态显示搜索失败,点重试回调', (tester) async {
    var retried = false;
    await pumpBody(
      tester,
      error: '网络断了',
      resultCount: 0,
      onRetrySearch: () => retried = true,
    );

    expect(find.text('搜索失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无结果显示空态', (tester) async {
    await pumpBody(tester, resultCount: 0);

    expect(find.text('没有结果'), findsOneWidget);
    expect(find.text('没有找到结果，换个关键词再试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有结果态显示结果数/页码与书名,点书回调', (tester) async {
    DisplayBook? opened;
    await pumpBody(
      tester,
      showResults: true,
      resultCount: 2,
      books: [_book('1', '心流'), _book('2', '当下的力量')],
      onOpenBook: (book) => opened = book,
    );

    expect(find.text('已显示 2 本书'), findsOneWidget);
    expect(find.text('第 1/3 页'), findsOneWidget);
    expect(find.text('心流'), findsOneWidget);
    expect(find.text('当下的力量'), findsOneWidget);
    await tester.tap(find.text('心流'));
    expect(opened?.id, '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('有结果时加载更多失败显示横幅,点重试回调', (tester) async {
    var retried = false;
    await pumpBody(
      tester,
      showResults: true,
      resultCount: 1,
      books: [_book('1', '心流')],
      error: '第 2 页失败',
      onRetryLoadMore: () => retried = true,
    );

    // 已有结果不清空:书还在,横幅只提示失败。
    expect(find.text('心流'), findsOneWidget);
    expect(find.text('加载更多失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });
}
