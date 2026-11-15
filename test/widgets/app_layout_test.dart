import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/home/widgets/home_book_grid.dart';
import 'package:zlibx/theme/app_layout.dart';
import 'package:zlibx/widgets/book_card.dart';

/// 自适应网格：列数公式（纯函数）+ 首页网格真的按公式排（widget）。
///
/// 这个开关有两档，两档都得钉住：
/// * 关（默认）= 1.6.0 之前的排布。首页走 `legacyGridColumns`，它就是
///   `SliverGridDelegateWithMaxCrossAxisExtent` 内部那个 ceil 公式，所以
///   升级上去看不到任何变化——把公式改回 floor，下面那两条 legacy 断言
///   立刻变红。
/// * 开 = 全站一套规则：列数、留白、间距都问 [AppLayout]，首页的纯封面
///   卡和列表页带书名信息的卡排同样的列数（手机 3 列起），只有格高按
///   卡片种类分开——见 [BookCard.gridHeightFor]。
/// 列数错了不会崩，只是整站看起来不对，所以公式和渲染两头都要钉住。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  _NoHiveAdaptive(this._value);

  final bool _value;

  /// 列数设置默认走 Hive 同步读；测试里不初始化 Hive，直接给要验的那一档。
  @override
  bool build() => _value;
}

List<DisplayBook> _books(int n) => [
  for (var i = 1; i <= n; i++)
    DisplayBook(
      id: 'layout-$i',
      title: 'Synthetic Grid $i',
      author: 'Author $i',
      tag: 'EPUB',
      tagExtra: '2022',
      meta: '1.02 MB',
      source: BookSource.zlibrary,
      cover: 'https://example.invalid/covers/$i.jpg',
    ),
];

/// 渲染首页网格并回它实际用的列数。
Future<int> _pumpGrid(
  WidgetTester tester, {
  required Size surface,
  required bool adaptive,
  int count = 6,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(adaptive)),
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
            booksAsync: AsyncValue.data(_books(count)),
            topPadding: 200,
            scrollController: ScrollController(),
            onRefresh: () async {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  final delegate =
      tester
          .widget<GridView>(find.byType(GridView))
          .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

/// 渲染一屏"带书名信息"的网格卡（最新上架 / 热门 / 同类 / 搜索结果共用
/// 的那种），用的就是那些页面自适应档的那个委托。首页之外的那几页没有
/// 独立的列数规则了，所以这里验的就是它们真实的排布。
Future<SliverGridDelegateWithFixedCrossAxisCount> _pumpFullCardGrid(
  WidgetTester tester, {
  required Size surface,
  bool searchResult = false,
  double? textScaler,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: textScaler == null
              ? null
              : TextScaler.linear(textScaler),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final delegate = BookCard.adaptiveGridDelegate(
              context,
              constraints.maxWidth,
            );
            return GridView.builder(
              padding: EdgeInsets.all(
                AppLayout.pageGutter(constraints.maxWidth),
              ),
              gridDelegate: delegate,
              itemCount: 6,
              itemBuilder: (context, index) => BookCard(
                book: _books(6)[index],
                searchResult: searchResult,
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return tester
      .widget<GridView>(find.byType(GridView))
      .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
}

void main() {
  group('AppLayout.gridColumns（全站唯一一条列数规则）', () {
    test('手机上恒为三列', () {
      // 360dp 的机器算术上只塞得下 2 张 112dp 的卡，但设计上手机就是
      // 三列，下限钉死在 3。
      expect(AppLayout.gridColumns(360), 3);
      expect(AppLayout.gridColumns(411), 3);
      expect(AppLayout.gridColumns(500), 3);
    });

    test('宽度真够三张 112dp 卡以上才加到四列', () {
      // 留白 20 时内容宽 496dp（窗口 536dp）刚好排下四列。
      expect(AppLayout.gridColumns(535), 3);
      expect(AppLayout.gridColumns(536), 4);
      expect(AppLayout.gridColumns(600), 4);
    });

    test('平板与桌面按宽度加列，封顶八列', () {
      // 840dp：内容 776dp，六列。
      expect(AppLayout.gridColumns(840), 6);
      // 1000dp：内容 936dp，七列。
      expect(AppLayout.gridColumns(1000), 7);
      // 1280dp：留白变宽后仍能排九列，但封顶在八。
      expect(AppLayout.gridColumns(1280), 8);
      expect(AppLayout.gridColumns(2400), 8);
    });
  });

  group('AppLayout.legacyGridColumns（开关关掉那一档）', () {
    test('ceil 公式：手机上就是两列', () {
      // 与 SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent:
      // 220, crossAxisSpacing: 16) 的 getLayout 逐像素同源：ceil，最少 1。
      expect(AppLayout.legacyGridColumns(320), 2); // 360dp - 2*20
      expect(AppLayout.legacyGridColumns(371), 2); // 411dp - 2*20
      expect(AppLayout.legacyGridColumns(200), 1);
      expect(AppLayout.legacyGridColumns(0), 1);
    });

    test('平板宽度上老规则也会加列', () {
      // 首页 1.6.0 在大屏上本来就是多列的，关档不是"永远两列"。
      expect(AppLayout.legacyGridColumns(560), 3); // 600dp - 2*20
      expect(AppLayout.legacyGridColumns(860), 4); // 900dp - 2*20
    });
  });

  test('页面左右留白随尺寸分档变宽', () {
    expect(AppLayout.pageGutter(400), 20);
    expect(AppLayout.pageGutter(600), 32);
    expect(AppLayout.pageGutter(1239), 32);
    expect(AppLayout.pageGutter(1240), 48);
  });

  group('首页网格真的按开关排', () {
    testWidgets('关掉时 360dp：两列（旧版观感）', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(360, 800),
        adaptive: false,
      );
      expect(columns, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关掉时 900dp：四列（ceil 老公式，留白固定 20）', (
      tester,
    ) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(900, 1600),
        adaptive: false,
      );
      expect(columns, 4);
      expect(tester.takeException(), isNull);
    });

    testWidgets('打开时 360dp：三列，卡片不溢出', (tester) async {
      // 360 是会被 ceil 公式打回两列的那一档（411 恰好还能塞下三列），
      // 所以用 360 验渲染，不只验公式。
      final columns = await _pumpGrid(
        tester,
        surface: const Size(360, 800),
        adaptive: true,
      );
      expect(columns, 3);
      expect(find.byType(BookCard), findsWidgets);
      // 三列密度（卡片 ≈101dp）下不许出现 RenderFlex 溢出。
      expect(tester.takeException(), isNull);
    });

    testWidgets('打开时 900dp：六列', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(900, 1600),
        adaptive: true,
      );
      expect(columns, 6);
      expect(tester.takeException(), isNull);
    });
  });

  group('带书名信息的网格卡也走同一条规则', () {
    // 信息区再怎么改版也不会低过 100dp：两行书名 34 + 分类行 14 +
    // 作者行 15 + 大小行 14 + 上下内边距 24 ≈ 101。这个下限写在测试里
    // 而不是抄 [BookCard] 的那个数——它钉的是"封面必须拿到 0.7 比例之外
    // 还剩整块信息区"，格子按老的 childAspectRatio（0.60/0.65）排时
    // 三列密度下封面被压成一条横带，这条就红。
    const minInfoHeight = 100.0;

    testWidgets('360dp：三列，且封面没被压成一条横带', (tester) async {
      final delegate = await _pumpFullCardGrid(
        tester,
        surface: const Size(360, 800),
      );
      expect(delegate.crossAxisCount, 3);
      expect(delegate.crossAxisSpacing, AppLayout.gridSpacing);
      final cellWidth =
          (360 -
              2 * AppLayout.pageGutter(360) -
              AppLayout.gridSpacing * 2) /
          3;
      expect(
        delegate.mainAxisExtent,
        greaterThanOrEqualTo(cellWidth / 0.7 + minInfoHeight),
        reason:
            '三列密度（格宽 ${cellWidth.toStringAsFixed(1)}dp）下'
            '一格只有 ${(delegate.mainAxisExtent ?? 0).toStringAsFixed(1)}dp 高',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('411dp 搜索结果卡：同样三列，不溢出', (tester) async {
      final delegate = await _pumpFullCardGrid(
        tester,
        surface: const Size(411, 900),
        searchResult: true,
      );
      expect(delegate.crossAxisCount, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('系统字号放大时格子跟着长高', (tester) async {
      // 信息区是格子里唯一按内容定高的一块，它随字号缩放；把
      // gridHeightFor 里的缩放拿掉（当成 1 倍算），这条就红。
      final normal = await _pumpFullCardGrid(
        tester,
        surface: const Size(411, 900),
      );
      final big = await _pumpFullCardGrid(
        tester,
        surface: const Size(411, 900),
        textScaler: 1.5,
      );
      expect(
        big.mainAxisExtent!,
        greaterThan(normal.mainAxisExtent!),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
