import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/models/grid_columns_mode.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/home/widgets/home_book_grid.dart';
import 'package:zlibx/theme/app_layout.dart';
import 'package:zlibx/widgets/book_card.dart';

/// 自适应网格：列数公式（纯函数）+ 首页网格真的按公式排（widget）。
///
/// 这条测试要守的是"宽度变了列数才变，手机密度不许悄悄掉"。旧实现按
/// `maxCardWidth = 220` 用 ceil 估列数，411dp 的手机上实际只有 2 列；
/// 现在手机固定 3 列、平板从 600dp 断点起加列。列数错了不会崩，只是
/// 整站看起来不对，所以公式和渲染两头都要钉住。
class _NoHiveGridMode extends HomeGridColumnsNotifier {
  _NoHiveGridMode(this._mode);

  final GridColumnsMode _mode;

  @override
  GridColumnsMode build() => _mode;
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

Future<int> _pumpGrid(
  WidgetTester tester, {
  required Size surface,
  required GridColumnsMode mode,
  int count = 6,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeGridColumnsModeProvider.overrideWith(() => _NoHiveGridMode(mode)),
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
  group('AppLayout.gridColumns', () {
    test('手机在任何宽度都是三列', () {
      // 360dp 的机器以前会掉到两列；设计上手机一直是三列，直到平板断点。
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 360), 3);
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 411), 3);
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 599), 3);
    });

    test('auto 从平板断点开始加列', () {
      // 600dp：内容 536dp，4 列。
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 600), 4);
      // 840dp：内容 776dp，6 列。
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 840), 6);
      // 1000dp：内容 936dp，7 列。
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 1000), 7);
      // 1280dp：宽留白后能排 9 列，但封顶在 8。
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 1280), 8);
    });

    test('auto 在超宽窗口封顶', () {
      expect(AppLayout.gridColumns(GridColumnsMode.auto, 2400), 8);
    });

    test('手动档无视宽度', () {
      expect(AppLayout.gridColumns(GridColumnsMode.two, 1200), 2);
      expect(AppLayout.gridColumns(GridColumnsMode.three, 1200), 3);
      expect(AppLayout.gridColumns(GridColumnsMode.four, 1200), 4);
      expect(AppLayout.gridColumns(GridColumnsMode.two, 360), 2);
    });

    test('只有 auto 把列数交给宽度', () {
      expect(GridColumnsMode.auto.fixedColumns, isNull);
      expect(GridColumnsMode.two.fixedColumns, 2);
      expect(GridColumnsMode.three.fixedColumns, 3);
      expect(GridColumnsMode.four.fixedColumns, 4);
    });

    test('四列档换的是渲染方式（纯封面格）', () {
      expect(GridColumnsMode.four.coverTiles, isTrue);
      expect(GridColumnsMode.auto.coverTiles, isFalse);
      expect(GridColumnsMode.three.coverTiles, isFalse);
      expect(GridColumnsMode.two.coverTiles, isFalse);
    });
  });

  test('页面左右留白随尺寸分档变宽', () {
    expect(AppLayout.pageGutter(400), 20);
    expect(AppLayout.pageGutter(600), 32);
    expect(AppLayout.pageGutter(1239), 32);
    expect(AppLayout.pageGutter(1240), 48);
  });

  group('首页网格真的按列数排', () {
    testWidgets('手机 360dp：三列，卡片不溢出', (tester) async {
      // 360 是会被旧公式打回两列的那一档（411 恰好还能塞下三列），所以
      // 用 360 验渲染，不只验公式。
      final columns = await _pumpGrid(
        tester,
        surface: const Size(360, 800),
        mode: GridColumnsMode.auto,
      );
      expect(columns, 3);
      expect(find.byType(BookCard), findsWidgets);
      // 三列密度（卡片 ≈101dp）下不许出现 RenderFlex 溢出。
      expect(tester.takeException(), isNull);
    });

    testWidgets('平板 900dp：六列', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(900, 1600),
        mode: GridColumnsMode.auto,
      );
      expect(columns, 6);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手动三列在平板上也保持三列', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(900, 1600),
        mode: GridColumnsMode.three,
      );
      expect(columns, 3);
    });

    testWidgets('四列档：四列且不渲染带信息区的卡片', (tester) async {
      final columns = await _pumpGrid(
        tester,
        surface: const Size(411, 900),
        mode: GridColumnsMode.four,
      );
      expect(columns, 4);
      expect(find.byType(BookCard), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
