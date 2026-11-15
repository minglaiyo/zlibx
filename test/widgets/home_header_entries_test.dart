import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/home_feed_provider.dart';
import 'package:zlibx/providers/update_provider.dart';
import 'package:zlibx/routes/app_routes.dart';
import 'package:zlibx/screens/home/home_tab.dart';
import 'package:zlibx/screens/popular/popular_books_screen.dart';
import 'package:zlibx/screens/recent/recent_books_screen.dart';
import 'package:zlibx/services/hive_service.dart';

/// 首页头部两个快捷入口的接线：HOT → 热门页，NEW → 最新上架页。
///
/// 这里守的是"按钮点到哪个路由"这一环——它两侧都是编译期符号引用，
/// analyze 只能保证方法存在，保证不了没接反；接反了整站照跑，只有
/// 真机点一下才发现。路由表本身由 app_routes_test 守，这里不重复。
class _SignedOutAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoading: false);
}

/// 首页 initState 的后帧回调会查一次更新，测试里不该出网。
class _NoUpdateCheck extends UpdateNotifier {
  @override
  Future<bool> checkForUpdate({bool force = false}) async => false;
}

Directory? _hiveDir;

Future<void> _pumpHome(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_SignedOutAuth.new),
        updateProvider.overrideWith(_NoUpdateCheck.new),
        homeRecommendedProvider.overrideWithValue(
          const AsyncValue<List<DisplayBook>>.data(<DisplayBook>[]),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // 只挂两个目标路由：buildAppRoutes() 含 "/"，和 home: 同时给会
        // 触发 WidgetsApp 断言。整张路由表由 app_routes_test 守。
        routes: {
          AppRoutes.popularBooks: (_) => const PopularBooksScreen(),
          AppRoutes.recentBooks: (_) => const RecentBooksScreen(),
        },
        home: const Scaffold(body: HomeTab()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(() async {
    // 头部要读 blur 开关，HomeBookGrid 要读列数开关，都落在 settings 盒。
    _hiveDir = await Directory.systemTemp.createTemp('home_header');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir?.delete(recursive: true);
  });

  testWidgets('头部只剩 HOT / NEW 两个徽标按钮，分类入口已让位', (tester) async {
    await _pumpHome(tester);
    expect(find.text('HOT'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.byIcon(Icons.category_outlined), findsNothing);
  });

  testWidgets('点 HOT 进热门页', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.text('HOT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PopularBooksScreen), findsOneWidget);
    expect(find.byType(RecentBooksScreen), findsNothing);
  });

  testWidgets('点 NEW 进最新上架页', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.text('NEW'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(RecentBooksScreen), findsOneWidget);
    expect(find.byType(PopularBooksScreen), findsNothing);
  });
}
