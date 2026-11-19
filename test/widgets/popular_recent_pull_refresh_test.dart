import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/screens/popular/popular_books_screen.dart';
import 'package:zlibx/screens/recent/recent_books_screen.dart';

/// 热门 / 最新上架两页（信息流版，2026-11-20）的下拉刷新与上滑加载。
///
/// 控制器逻辑（累积 / 去重 / 收口）在 feed_controller_test.dart 里数；
/// 这里数 UI 手势真的接到控制器上：数据态下拉重拉、卡在加载档也能下拉、
/// 错误态下拉重试、上滑到底真的追加下一页。
class _NoHiveAdaptive extends AdaptiveGridNotifier {
  _NoHiveAdaptive(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

Book _book(int id) => Book(id: id, title: '书$id');

/// 假接口：热门快照 + popular 搜索续页 + date 搜索分页都可配，按序
/// 记账；快照可以挂死（加载档卡住用）或先失败后成功（错误重试用）。
class _FakeFeedApi implements ZLibraryApi {
  int snapshotCalls = 0;
  int searchPopularCalls = 0;
  int searchDateCalls = 0;

  List<Book> snapshot = [for (var i = 1; i <= 20; i++) _book(i)];
  bool failSnapshotFirst = false;
  Completer<ApiResponse<List<Book>>>? hangSnapshot;

  /// popular 搜索续页（loadMore 用）；缺页 = 空列表。
  Map<int, List<Book>> popularPages = {2: [_book(3), _book(4)]};

  /// date 搜索分页（最新页第 1 页与续页共用）。
  Map<int, List<Book>> datePages = {
    1: [for (var i = 1; i <= 20; i++) _book(i)],
    2: [_book(21), _book(22)],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<List<Book>>> getMostPopular({int? page}) async {
    snapshotCalls++;
    if (failSnapshotFirst && snapshotCalls == 1) {
      return ApiResponse.fail('synthetic boom');
    }
    final hang = hangSnapshot;
    if (hang != null) return hang.future;
    return ApiResponse.ok(snapshot);
  }

  @override
  Future<ApiResponse<List<Book>>> search({
    String? message,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int? page,
    int? limit,
    bool? exact,
    CancelToken? cancelToken,
  }) async {
    final key = order ?? '';
    if (key == 'popular') searchPopularCalls++;
    if (key == 'date') searchDateCalls++;
    final pages = key == 'date' ? datePages : popularPages;
    return ApiResponse.ok(pages[page ?? 1] ?? const <Book>[]);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget screen,
  required _FakeFeedApi api,
  Size surface = const Size(411, 900),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        zlibraryApiProvider.overrideWithValue(api),
        adaptiveGridProvider.overrideWith(() => _NoHiveAdaptive(false)),
      ],
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
  await tester.pump(const Duration(milliseconds: 300));
}

/// 下拉手势（数据态在网格上拉；其它档从屏幕顶部拉，反正那一档没有
/// 网格）。越界量要够：RefreshIndicator 的触发阈值是 viewport × 0.25 / 1.5。
Future<void> _pull(WidgetTester tester, {bool fromGrid = true}) async {
  if (fromGrid && find.byType(GridView).evaluate().isNotEmpty) {
    await tester.drag(find.byType(GridView), const Offset(0, 400));
  } else {
    await tester.dragFrom(const Offset(205, 150), const Offset(0, 400));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('热门页', () {
    testWidgets('数据态下拉重新拉取：快照接口真的被再次调用', (tester) async {
      final api = _FakeFeedApi();
      await _pump(tester, screen: const PopularBooksScreen(), api: api);
      expect(api.snapshotCalls, 1);
      expect(find.byType(GridView), findsOneWidget);

      await _pull(tester);
      expect(api.snapshotCalls, 2, reason: '刷新没有重新拉取');
    });

    testWidgets('卡在加载档也能下拉：重拉真的发出，接口到货后出内容', (tester) async {
      final api = _FakeFeedApi()
        ..hangSnapshot = Completer<ApiResponse<List<Book>>>();
      await _pump(tester, screen: const PopularBooksScreen(), api: api);
      expect(find.byType(GridView), findsNothing);

      await _pull(tester, fromGrid: false);
      expect(api.snapshotCalls, 2, reason: '加载档的下拉没有接到重拉');

      // 接口到货：卡住的那次与重拉都解出来，内容照常上屏。
      api.hangSnapshot!.complete(ApiResponse.ok([_book(1)]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('错误态下拉重试：第二次成功后出内容', (tester) async {
      final api = _FakeFeedApi()..failSnapshotFirst = true;
      await _pump(tester, screen: const PopularBooksScreen(), api: api);
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await _pull(tester, fromGrid: false);
      expect(api.snapshotCalls, 2);
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('上滑到底：loadMore 追加 popular 搜索续页', (tester) async {
      final api = _FakeFeedApi();
      await _pump(tester, screen: const PopularBooksScreen(), api: api);
      expect(find.byType(GridView), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(GridView), const Offset(0, -1600));
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      // 契约:上滑到底触发 loadMore(请求真的发出)。追加后的条目数由
      // 控制器层测试钉(feed_controller_test),这里不数 UI 格子。
      expect(api.searchPopularCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('最新上架页', () {
    testWidgets('数据态下拉重新拉取：date 搜索真的被再次调用', (tester) async {
      final api = _FakeFeedApi();
      await _pump(tester, screen: const RecentBooksScreen(), api: api);
      expect(api.searchDateCalls, 1);

      await _pull(tester);
      expect(api.searchDateCalls, 2, reason: '刷新没有重新拉取');
    });

    testWidgets('上滑到底：loadMore 追加 date 搜索第 2 页', (tester) async {
      final api = _FakeFeedApi();
      await _pump(tester, screen: const RecentBooksScreen(), api: api);
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(GridView), const Offset(0, -1600));
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(api.searchDateCalls, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });
  });
}
