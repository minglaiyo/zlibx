import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/widgets/book_card.dart';
import 'package:zlibx/widgets/cover_placeholder.dart';

/// 网格卡片（最新上架 / 热门 / 同类）的书名区：真实栅格几何下，
/// 两行中文书名必须整行显示，且长短书名的卡片版式一致。
///
/// 守的是 2026-11-15 用户截图那个毛病：信息区当时是 Expanded(flex: 2)
/// 固定一档，360dp 窄屏上那档留给两行书名只剩 ~18px，第二行只露半截。
/// 裁半截不抛异常、不报 RenderFlex 溢出，只能量出来——所以这里比对
/// 书名框的实际高度和同宽度下 TextPainter 算出的需要高度。
void main() {
  const longCjkTitle = '阶级与话语之间：左翼知识分子的资本主义辩护';
  const shortTitle = '树新义室笔谈';

  DisplayBook gridBook(String title) => DisplayBook(
    id: 'grid-$title',
    title: title,
    author: '[俄]鲍里斯 卡加利茨基',
    tag: 'PDF',
    tagExtra: '2021',
    meta: '5.02 MB',
    source: BookSource.zlibrary,
  );

  /// 与 recent_books_screen / popular_books_screen 同参数的栅格。
  Future<void> pumpGrid(
    WidgetTester tester, {
    required double surfaceWidth,
    double textScale = 1.0,
    List<String> titles = const [longCjkTitle, shortTitle],
  }) async {
    await tester.binding.setSurfaceSize(Size(surfaceWidth, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: titles.length,
            itemBuilder: (context, index) =>
                BookCard(book: gridBook(titles[index])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 同宽度下把书名排两行需要多高。字号/行高就是卡片书名的规格
  /// （14px × 1.2 × 2 行 = 33.6），这里刻意写死，改规格要过这条测试。
  double neededTitleHeight(String title, double maxWidth, double scale) {
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(fontSize: 14 * scale, height: 1.2),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    return painter.height;
  }

  testWidgets('窄屏 360dp：两行中文书名整行显示，不裁半截', (tester) async {
    await pumpGrid(tester, surfaceWidth: 360);
    expect(tester.takeException(), isNull);

    final box = tester.getSize(find.text(longCjkTitle));
    // 栅格算出的卡片宽：(360 - 左右内边距 32 - 列间距 12) / 2 = 158，
    // 书名区再扣卡片内边距 12*2。
    final cardWidth = (360 - 32 - 12) / 2;
    final needed = neededTitleHeight(longCjkTitle, cardWidth - 24, 1.0);
    expect(needed, greaterThan(0));
    // 两行需要 34.0；旧版只给到 ~18，第二行被裁。
    expect(box.height, greaterThanOrEqualTo(needed));
    // 书名按两行排（截断处补省略号），不是一行。
    expect(tester.widget<Text>(find.text(longCjkTitle)).maxLines, 2);
  });

  testWidgets('长短书名的书名槽位对齐，封面等高', (tester) async {
    await pumpGrid(tester, surfaceWidth: 360);
    expect(tester.takeException(), isNull);

    // 槽位是下限不是定高：两行书名按真实高度排（Skia 把 16.8 的行盒
    // 进位成 17.0，两行 34.0），单行书名补足到同一档。所以这里要的是
    // "都不低于两行、彼此相差不超过一像素"，不是严格相等。
    final longBox = tester.getSize(find.text(longCjkTitle));
    final shortBox = tester.getSize(find.text(shortTitle));
    expect(longBox.height, greaterThanOrEqualTo(33.6));
    expect(shortBox.height, greaterThanOrEqualTo(33.6));
    expect((longBox.height - shortBox.height).abs(), lessThan(1.0));

    expect(find.byType(CoverPlaceholder), findsNWidgets(2));
    expect(
      (tester.getSize(find.byType(CoverPlaceholder).first).height -
              tester.getSize(find.byType(CoverPlaceholder).last).height)
          .abs(),
      lessThan(1.0),
    );
  });

  testWidgets('放大字号下长短书名仍然对齐：槽位下限跟着字号走', (tester) async {
    await pumpGrid(tester, surfaceWidth: 360, textScale: 1.5);
    expect(tester.takeException(), isNull);

    // 1.5 倍字号时两行真实需要 52.0：槽位下限若不带 titleScale，单行
    // 书名只占 33.6，同屏封面就差出一整行。
    final longBox = tester.getSize(find.text(longCjkTitle));
    final shortBox = tester.getSize(find.text(shortTitle));
    expect(longBox.height, greaterThanOrEqualTo(50.0));
    expect((longBox.height - shortBox.height).abs(), lessThan(1.0));
    expect(
      (tester.getSize(find.byType(CoverPlaceholder).first).height -
              tester.getSize(find.byType(CoverPlaceholder).last).height)
          .abs(),
      lessThan(1.0),
    );
  });

  testWidgets('放大字号 1.5 倍仍不裁、不溢出', (tester) async {
    await pumpGrid(tester, surfaceWidth: 360, textScale: 1.5);
    expect(tester.takeException(), isNull);

    final box = tester.getSize(find.text(longCjkTitle));
    final cardWidth = (360 - 32 - 12) / 2;
    final needed = neededTitleHeight(longCjkTitle, cardWidth - 24, 1.5);
    expect(box.height, greaterThanOrEqualTo(needed));
  });

  testWidgets('宽屏 411dp：书名两行同样完整', (tester) async {
    await pumpGrid(tester, surfaceWidth: 411);
    expect(tester.takeException(), isNull);

    final box = tester.getSize(find.text(longCjkTitle));
    final cardWidth = (411 - 32 - 12) / 2;
    final needed = neededTitleHeight(longCjkTitle, cardWidth - 24, 1.0);
    expect(box.height, greaterThanOrEqualTo(needed));
  });

  const book = DisplayBook(
    id: 'test-book',
    title: '这是一本书名很长的推荐书籍 A very long recommended book title',
    author: '名字很长的作者 A very long author name',
    score: '9.8',
    meta: '123456789 人正在阅读这本书',
    tag: '文学',
    tagExtra: '2026',
    source: BookSource.zlibrary,
  );

  for (final brightness in Brightness.values) {
    for (final width in [132.0, 172.0, 216.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('compact card: $brightness, width $width, scale $scale', (
          tester,
        ) async {
          final scaler = TextScaler.linear(scale);
          final semantics = tester.ensureSemantics();
          try {
            var tapped = false;
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: scaler),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      height: BookCard.compactHeightFor(width),
                      child: BookCard(
                        book: book,
                        compact: true,
                        onTap: () => tapped = true,
                      ),
                    ),
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            // Compact cards overlay the title + author on the cover when
            // there is no cover image (fallback book info), so both render
            // as visible Text; only score/tag stay hidden, and the title
            // remains available as a semantics label.
            expect(find.text(book.title), findsOneWidget);
            expect(find.text(book.author!), findsOneWidget);
            expect(find.text(book.score!), findsNothing);
            expect(
              find.bySemanticsLabel(RegExp(RegExp.escape(book.title))),
              findsOneWidget,
            );
            expect(find.byIcon(Icons.auto_stories_rounded), findsOneWidget);
            expect(find.text(book.tag!), findsNothing);
            await tester.tap(find.byType(BookCard));
            await tester.pumpAndSettle();
            expect(tapped, isTrue);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  testWidgets('compact card handles missing optional details', (tester) async {
    const sparseBook = DisplayBook(
      id: 'sparse',
      title: '只有书名',
      source: BookSource.zlibrary,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 132,
            height: BookCard.compactHeightFor(132),
            child: const BookCard(book: sparseBook, compact: true),
          ),
        ),
      ),
    );
    // Same fallback overlay as above: a coverless card still shows the title.
    expect(find.text(sparseBook.title), findsOneWidget);
    expect(find.byIcon(Icons.auto_stories_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default card still displays category and extra details', (
    tester,
  ) async {
    const defaultBook = DisplayBook(
      id: 'default',
      title: '默认卡片',
      author: '作者',
      tag: '文学',
      tagExtra: '2026',
      score: '9.8',
      meta: '123 人在读',
      source: BookSource.zlibrary,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 172,
            height: 300,
            child: BookCard(book: defaultBook),
          ),
        ),
      ),
    );
    expect(find.text(defaultBook.tag!), findsOneWidget);
    expect(find.text('• ${defaultBook.tagExtra}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
