import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/recent/recent_books_screen.dart';
import 'package:zlibx/widgets/book_card.dart';

/// [RecentBooksScreen] 的三态渲染：数据网格、空态、错误态。
/// recentBooksProvider 用 overrideWith 直接供假数据/假错误，
/// 不触网络；封面走 example.invalid 快速失败到占位图。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  _NoHiveAdaptive(this._value);

  final bool _value;

  /// 自适应列数默认走 Hive 同步读；测试里不初始化 Hive，直接给要验的那档。
  @override
  bool build() => _value;
}

/// 网格实际用的列数（自适应那档才可能不是 2）。
int _gridColumns(WidgetTester tester) =>
    (tester.widget<GridView>(find.byType(GridView)).gridDelegate
            as SliverGridDelegateWithFixedCrossAxisCount)
        .crossAxisCount;

List<Book> _fakeBooks() => [
  for (var i = 1; i <= 6; i++)
    Book(
      id: 100 + i,
      title: 'Synthetic Recent $i',
      author: 'Author $i',
      cover: 'https://example.invalid/covers/$i.jpg',
    ),
];

Future<void> _pump(
  WidgetTester tester, {
  required FutureOr<List<Book>> Function(Ref ref) create,
  bool adaptive = false,
  Size surface = const Size(800, 1600),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentBooksProvider.overrideWith((ref, page) => create(ref)),
        adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(adaptive)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const RecentBooksScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('数据态：6 本假书全部渲染为卡片', (tester) async {
    final books = _fakeBooks();
    await _pump(tester, create: (ref) async => books);
    expect(find.byType(BookCard), findsNWidgets(6));
    expect(find.text('Synthetic Recent 1'), findsOneWidget);
  });

  testWidgets('自适应列数关掉（默认）：800dp 上仍是两列', (tester) async {
    final books = _fakeBooks();
    await _pump(tester, create: (ref) async => books);
    expect(_gridColumns(tester), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自适应列数打开：800dp 上排五列，卡片不溢出', (tester) async {
    final books = _fakeBooks();
    await _pump(tester, create: (ref) async => books, adaptive: true);
    // 与首页同一条规则：800dp 内容 736dp，按 112dp 的下限排五列
    // （每格 ≈134dp）。
    expect(_gridColumns(tester), 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自适应列数打开：360dp 手机上也是三列', (tester) async {
    // 这类带书名信息的卡以前在手机上恒 2 列（怕窄格把封面压成一条）；
    // 现在格高按"封面 0.7 + 信息区"算，密度和首页对齐，三列不溢出。
    final books = _fakeBooks();
    await _pump(
      tester,
      create: (ref) async => books,
      adaptive: true,
      surface: const Size(360, 800),
    );
    expect(_gridColumns(tester), 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态：显示空态文案', (tester) async {
    await _pump(tester, create: (ref) async => <Book>[]);
    expect(find.byType(BookCard), findsNothing);
    expect(find.text('Nothing new has been added yet'), findsOneWidget);
  });

  testWidgets('错误态：显示错误与重试入口，重试不抛异常', (tester) async {
    await _pump(
      tester,
      create: (ref) => Future.error(StateError('synthetic boom')),
    );
    expect(find.byType(BookCard), findsNothing);
    // 右上角 app bar 的刷新按钮已去掉（加载档现在没有任何视觉），本页
    // 剩下的唯一 Icons.refresh 是错误态的重试按钮。
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    // 重试按钮触发 invalidate：新的 provider 构建再次失败也只刷新
    // 错误信息，不抛出。
    await tester.tap(
      find.descendant(
        of: find.byType(TextButton),
        matching: find.byIcon(Icons.refresh),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
