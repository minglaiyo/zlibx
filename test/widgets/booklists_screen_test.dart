// P2-6: BooklistsScreen 屏幕级三态。只拼已验证的套子:假的
// BooklistsController(直接回整态,动作全是 no-op)+假的
// RecommendedBooklistsController(空推荐)。屏幕 build 只 watch
// 这两个 provider(玻璃头部另看 blurEnabledProvider,读 Hive
// settingsBox,所以这里也要开一个临时 Hive 目录)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/recommended_booklists_provider.dart';
import 'package:zlibx/screens/account/booklists_screen.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/widgets/booklist_card.dart';
import 'package:zlibx/widgets/empty_state.dart';

class _FakeBooklistsController extends BooklistsController {
  _FakeBooklistsController(this._state);

  final BooklistsState _state;

  int loadFirstCalls = 0;

  @override
  BooklistsState build() => _state;

  @override
  void setTab(BooklistTab tab) {}

  @override
  void search(String query) {}

  @override
  void setOrder(String order) {}

  @override
  Future<void> loadFirst() async {
    loadFirstCalls++;
  }

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> refresh() async {}
}

class _FakeRecommendedController extends RecommendedBooklistsController {
  @override
  RecommendedBooklistsState build() =>
      const RecommendedBooklistsState(isLoading: false, lists: []);
}

Booklist _list(String id) => Booklist(
  id: id,
  name: 'Synthetic List $id',
  author: 'Synthetic Author',
  count: 2,
  url: 'https://example.invalid/booklist/$id',
);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('booklists_screen_hive');
    Hive.init(hiveDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    addTearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required BooklistsState state,
    _FakeBooklistsController? fake,
  }) async {
    final controller = fake ?? _FakeBooklistsController(state);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          booklistsControllerProvider.overrideWith(() => controller),
          recommendedBooklistsProvider.overrideWith(
            () => _FakeRecommendedController(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const BooklistsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('加载态显示骨架屏', (tester) async {
    await pumpScreen(
      tester,
      state: const BooklistsState(phase: BooklistsPhase.loading),
    );

    expect(find.byType(BooklistSkeletonList), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误态显示错误与重试,点重试重新加载', (tester) async {
    final fake = _FakeBooklistsController(
      const BooklistsState(phase: BooklistsPhase.error, error: 'boom'),
    );
    await pumpScreen(tester, state: fake.build(), fake: fake);

    expect(find.text('boom'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(fake.loadFirstCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('就绪空态显示暂无书单', (tester) async {
    await pumpScreen(
      tester,
      state: const BooklistsState(phase: BooklistsPhase.ready),
    );

    expect(find.byType(EmptyState), findsWidgets);
    expect(find.text('暂无书单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('就绪态渲染书单名', (tester) async {
    await pumpScreen(
      tester,
      state: BooklistsState(
        phase: BooklistsPhase.ready,
        lists: [_list('90001')],
      ),
    );

    expect(find.text('Synthetic List 90001'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
