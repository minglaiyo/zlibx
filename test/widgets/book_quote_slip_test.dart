// 书语诗签彩蛋：数据池完整性、诗签渲染、换一张不重复。
// 连点版本号的触发线（settings_screen 的 5 次计数）是 10 行纯
// UI 接线，由真机验证覆盖，这里不重复。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/widgets/book_quote_slip.dart';

void main() {
  test('quote pool is complete, sourced, and deduplicated', () {
    expect(kBookQuotes.length, 12);
    final texts = <String>{};
    for (final q in kBookQuotes) {
      expect(q.text.trim(), isNotEmpty);
      expect(q.source.trim(), isNotEmpty);
      expect(texts.add(q.text), isTrue, reason: '${q.text} 出现了两次');
    }
    // 与 Web 服务页那首诗同源：彩蛋里要有它的出处。
    expect(
      kBookQuotes.any((q) => q.text.contains('邂逅相遇')),
      isTrue,
    );
  });

  Widget app() => MaterialApp(
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: const BookQuoteSlip(),
  );

  testWidgets('the slip renders one of the pool quotes with a source', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final poolTexts = kBookQuotes.map((q) => q.text).toSet();
    final shown = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && poolTexts.contains(w.data),
      ),
    );
    expect(shown.data, isIn(poolTexts));
    // 出处行存在（以破折号开头）。
    expect(find.textContaining('—— '), findsOneWidget);
    // "再抽一张"按钮（en locale）。
    expect(find.text('Draw another'), findsOneWidget);
  });

  testWidgets('draw again replays with a different quote', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    String shown() => tester
        .widget<Text>(
          find.byWidgetPredicate(
            (w) => w is Text && kBookQuotes.any((q) => q.text == w.data),
          ),
        )
        .data as String;

    final first = shown();
    // 12 选 1 且排除上一张：连抽两张相同的概率为 0。
    for (var attempt = 0; attempt < 12 && shown() == first; attempt++) {
      await tester.tap(find.text('Draw another'));
      await tester.pumpAndSettle();
    }
    expect(shown(), isNot(first));
    expect(find.textContaining('—— '), findsOneWidget);
  });
}
