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
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentBooksProvider.overrideWith(create),
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

  testWidgets('自适应列数打开：800dp 上排四列，卡片不溢出', (tester) async {
    final books = _fakeBooks();
    await _pump(tester, create: (ref) async => books, adaptive: true);
    // 800dp：内容 736dp，按 168dp 的下限排四列（每格 ≈175dp）。
    expect(_gridColumns(tester), 4);
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
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    // 重试按钮触发 invalidate：新的 provider 构建再次失败也只刷新
    // 错误信息，不抛出。
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
