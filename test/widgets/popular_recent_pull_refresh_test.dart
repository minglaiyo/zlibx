import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/screens/popular/popular_books_screen.dart';
import 'package:zlibx/screens/recent/recent_books_screen.dart';

/// 热门 / 最新上架两页的刷新。
///
/// 两页都是从首页"更多"推进来的二级页，body 是一个 RefreshIndicator 包
/// `booksAsync.when(...)`。AsyncValue 有四档内容（加载 / 错误 / 空 / 数据），
/// 每一档都得给一个能越界滚动的子组件，下拉手势才落得到（和首页
/// home_book_grid_refresh_test.dart 同一条道理）；app bar 上另有显式刷新
/// 按钮，卡片没铺满一屏时它是更稳的入口。
///
/// 这里数的是 provider 真的被重新构建、请求真的重发，不是"转圈动画看起来
/// 有"。2026-11-15 的回归就在加载档：那里放的是不可滚动的
/// `LoadingWidget.page()`，接口慢 / 被墙时页面一直停在这一档，下拉完全没
/// 反应，等于"刷新不了"。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  _NoHiveAdaptive(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

List<Book> _books() => [
  for (var i = 1; i <= 6; i++)
    Book(
      id: 100 + i,
      title: 'Synthetic $i',
      author: 'Author $i',
      cover: 'https://example.invalid/covers/$i.jpg',
    ),
];

/// provider 被构建的第几次调用（1 = 首屏，2 = 刷新那一轮）。
typedef _Create = FutureOr<List<Book>> Function(int call);

/// 刷新方式：`grid` = 数据态在网格里下拉；`top` = 没有网格的那几档（加载 /
/// 错误）从屏幕顶部下拉，就是用户手指的动作；`button` = 点右上角刷新按钮。
enum _Via {
  grid,
  top,
  button,
}

/// 执行一次刷新，回 provider 被构建的次数（1 = 首屏；2 = 请求真的重发过）。
Future<int> _pullAndCountBuilds(
  WidgetTester tester, {
  required Widget screen,
  required FutureProvider<List<Book>> provider,
  required _Create create,
  _Via via = _Via.grid,
  bool adaptive = false,
}) async {
  var builds = 0;
  await tester.binding.setSurfaceSize(const Size(411, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      provider.overrideWith((ref) {
        builds++;
        return create(builds);
      }),
      adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(adaptive)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(builds, 1, reason: '首屏只该发一次请求');
  // 越界量要够：RefreshIndicator 的触发阈值是 viewport × 0.25 / 1.5。
  if (via == _Via.grid) {
    expect(find.byType(GridView), findsOneWidget);
    await tester.drag(find.byType(GridView), const Offset(0, 400));
  } else if (via == _Via.top) {
    await tester.dragFrom(const Offset(205, 150), const Offset(0, 400));
  } else {
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.refresh),
      ),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 1));
  expect(builds, greaterThan(1), reason: '刷新没有重新拉取');
  return builds;
}

void main() {
  for (final (title, isRecent) in [('热门', false), ('最新上架', true)]) {
    final provider = isRecent
        ? recentBooksProvider
        : mostPopularBooksProvider;
    Widget screen() =>
        isRecent ? const RecentBooksScreen() : const PopularBooksScreen();

    testWidgets('$title：数据态下拉重新拉取', (tester) async {
      await _pullAndCountBuilds(
        tester,
        screen: screen(),
        provider: provider,
        create: (call) async => _books(),
      );
    });

    testWidgets('$title：自适应列数打开时照样能下拉', (tester) async {
      await _pullAndCountBuilds(
        tester,
        screen: screen(),
        provider: provider,
        create: (call) async => _books(),
        adaptive: true,
      );
    });

    testWidgets('$title：卡在加载态（接口不返回）也要能下拉重拉', (tester) async {
      await _pullAndCountBuilds(
        tester,
        screen: screen(),
        provider: provider,
        create: (call) => Completer<List<Book>>().future,
        via: _Via.top,
      );
    });

    testWidgets('$title：错误态下拉重新拉取', (tester) async {
      await _pullAndCountBuilds(
        tester,
        screen: screen(),
        provider: provider,
        create: (call) =>
            call == 1 ? Future.error(StateError('synthetic boom')) : _books(),
        via: _Via.top,
      );
    });

    testWidgets('$title：加载态点右上角刷新按钮也重发请求', (tester) async {
      await _pullAndCountBuilds(
        tester,
        screen: screen(),
        provider: provider,
        create: (call) => Completer<List<Book>>().future,
        via: _Via.button,
      );
    });
  }

  testWidgets('刷新跟着请求走完，指示器不提前收起（两页）', (tester) async {
    for (final isRecent in [false, true]) {
      final first = Completer<List<Book>>();
      final second = Completer<List<Book>>();
      var calls = 0;
      final provider = isRecent
          ? recentBooksProvider
          : mostPopularBooksProvider;
      await tester.binding.setSurfaceSize(const Size(411, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(
        overrides: [
          provider.overrideWith((ref) {
            calls++;
            return calls == 1 ? first.future : second.future;
          }),
          adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(false)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: isRecent
                ? const RecentBooksScreen()
                : const PopularBooksScreen(),
          ),
        ),
      );
      first.complete(_books());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(GridView), findsOneWidget);

      // 直接取 RefreshIndicator 的回调：它返回的 future 什么时候完成，决定
      // 指示器什么时候收起。
      final onRefresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh;
      var finished = false;
      unawaited(onRefresh().then((_) => finished = true));
      await tester.pump();
      expect(calls, 2);
      expect(
        finished,
        isFalse,
        reason: 'onRefresh 没等请求结束就返回：慢线时转圈一闪而过，'
            '看起来就是"拉了没反应"（isRecent=$isRecent）',
      );
      second.complete(_books());
      await tester.pump();
      expect(
        finished,
        isTrue,
        reason: '请求结束后指示器还收不起来（isRecent=$isRecent）',
      );
      // riverpod 的 invalidate 会排一个零时长调度 timer，推进一次假时钟
      // 让它跑完，否则测试收尾会报 "A Timer is still pending"。
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
