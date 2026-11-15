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
/// * 开 = 按窗口宽度排布：纯封面卡（首页）手机 3 列起，带书名信息的卡
///   （最新上架 / 热门 / 同类 / 搜索）恒 2 列起、平板才加列。
/// 列数错了不会崩，只是整站看起来不对，所以公式和渲染两头都要钉住。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  _NoHiveAdaptive(this._value);

  final bool _value;

  /// 列数设置默认走 Hive 同步读；测试里不初始化 Hive，直接给要验的那一档。
  @override
  bool build() => _value;
}

class _NoHiveFourColumns extends HomeGridFourColumnsNotifier {
  _NoHiveFourColumns(this._value);

  final bool _value;

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
  bool fourColumns = false,
  int count = 6,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(adaptive)),
        homeGridFourColumnsProvider.overrideWith(
          () => _NoHiveFourColumns(fourColumns),
        ),
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

void main() {
  group('AppLayout.gridColumns（纯封面卡：首页）', () {
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

  group('AppLayout.fullCardGridColumns（带书名信息的卡：列表页）', () {
    test('手机上保持两列', () {
      // 这类卡片的信息区按内容占掉 ~118dp，卡片压到 168dp 以下封面就塌
      // 成一条，所以手机不许因为"自适应"就排成三列。
      expect(AppLayout.fullCardGridColumns(360), 2);
      expect(AppLayout.fullCardGridColumns(411), 2);
      expect(AppLayout.fullCardGridColumns(500), 2);
    });

    test('平板起按 168dp 的下限加列', () {
      expect(AppLayout.fullCardGridColumns(600), 3);
      expect(AppLayout.fullCardGridColumns(800), 4);
      expect(AppLayout.fullCardGridColumns(840), 4);
      expect(AppLayout.fullCardGridColumns(1000), 5);
      expect(AppLayout.fullCardGridColumns(1280), 6);
      expect(AppLayout.fullCardGridColumns(2400), 8);
    });

    test('加列时每格仍不低于 168dp', () {
      // 列数公式和间距是一对：间距改了这里就会红。
      for (final width in <double>[600, 800, 1000, 1280, 1600, 2400]) {
        final columns = AppLayout.fullCardGridColumns(width);
        final contentWidth = width - 2 * AppLayout.pageGutter(width);
        final cellWidth =
            (contentWidth - AppLayout.listGridSpacing * (columns - 1)) /
            columns;
        expect(
          cellWidth,
          greaterThanOrEqualTo(AppLayout.fullCardMinCardWidth),
          reason: '${width}dp 排 $columns 列只剩 ${cellWidth}dp 宽',
        );
      }
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

    testWidgets('四列布局是独立开关，且压过自适应', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(411, 900),
        adaptive: true,
        fourColumns: true,
      );
      expect(columns, 4);
      // 四列档换的是渲染方式：纯封面格，不再有带信息区的卡片。
      expect(find.byType(BookCard), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
