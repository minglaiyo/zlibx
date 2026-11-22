import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/screens/downloads/local_downloads_screen.dart';
import 'package:zlibx/services/hive_service.dart';

/// 下载页「已完成」Tab 的分类筛选（方案 C1）：chips 与书架共用同一棵
/// 分类树（Hive shelf_categories_v1），键 `download:<bookId>`。
/// Hive 在 setUpAll 里种子化，testWidgets 内不写 Hive（FakeAsync 区
/// put 落盘 Future 不完成，见 settings_privacy_incognito_test 的教训）。

DownloadTask _task(String id, String title) => DownloadTask(
  id: id,
  book: Book(id: int.parse(id), title: title, author: 'A'),
  status: DownloadStatus.completed,
  downloadedAt: DateTime(2026, 11, 18, 10, id.hashCode % 60),
  fileSize: 1024,
);

Widget app(List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: const LocalDownloadsScreen(),
  ),
);

void main() {
  Directory? hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('downloads_cat_test');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
    // 预置分类树：Fiction 分类 + book 2 已归类。
    await HiveService.settingsBox.put(
      'shelf_categories_v1',
      jsonEncode({
        'categories': [
          {'id': 'c1', 'name': 'Fiction'},
        ],
        'assignments': {'download:2': 'c1'},
      }),
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir!.delete(recursive: true);
  });

  List<Override> overrides() => [
    downloadListStructureProvider.overrideWithValue(
      DownloadListStructure(
        ongoingIds: [],
        completedIds: ['1', '2'],
        completedDates: {
          '1': DateTime(2026, 11, 18, 10),
          '2': DateTime(2026, 11, 18, 10),
        },
      ),
    ),
    downloadTaskProvider(
      '1',
    ).overrideWithValue(_task('1', 'Downloaded one')),
    downloadTaskProvider(
      '2',
    ).overrideWithValue(_task('2', 'Downloaded two')),
  ];

  testWidgets('分类 chips 显示计数，点分类过滤已完成列表', (tester) async {
    await tester.pumpWidget(app(overrides()));
    await tester.pumpAndSettle();

    // 默认「进行中」Tab：切到「已完成」。
    await tester.tap(find.text('Completed (2)'));
    await tester.pumpAndSettle();

    expect(find.text('Downloaded one'), findsOneWidget);
    expect(find.text('Downloaded two'), findsOneWidget);
    // chips：全部 2 / Uncategorized 1 / Fiction 1。
    expect(find.textContaining('All categories 2'), findsOneWidget);
    expect(find.textContaining('Fiction 1'), findsOneWidget);

    await tester.tap(find.textContaining('Fiction 1'));
    await tester.pumpAndSettle();
    expect(find.text('Downloaded one'), findsNothing);
    expect(find.text('Downloaded two'), findsOneWidget);
    // 空态文案随筛选变化（未分类分支走到 shelfNoMatches）。
    await tester.tap(find.textContaining('All categories'));
    await tester.pumpAndSettle();
    expect(find.text('Downloaded one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wifi-only 拒绝态显示专属文案，pending 任务菜单有置顶', (tester) async {
    final blocked = DownloadTask(
      id: '9',
      book: const Book(id: 9, title: 'Blocked one', author: 'A'),
      status: DownloadStatus.error,
      wifiOnlyBlocked: true,
    );
    final pending = DownloadTask(
      id: '8',
      book: const Book(id: 8, title: 'Queued one', author: 'A'),
      status: DownloadStatus.pending,
    );
    await tester.pumpWidget(
      app([
        downloadListStructureProvider.overrideWithValue(
          const DownloadListStructure(
            ongoingIds: ['8'],
            completedIds: ['9'],
            // Task '9' is an error task with no downloadedAt.
            completedDates: {'9': null},
          ),
        ),
        downloadTaskProvider('8').overrideWithValue(pending),
        downloadTaskProvider('9').overrideWithValue(blocked),
      ]),
    );
    // pending 行带不确定进度条（循环动画，pumpAndSettle 永不结束），
    // 全程用定步进 pump。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // E1：wifi-only 旗标的错误文案（不是裸 error 字符串）。先切
    // Completed 再开菜单——模态菜单会吞掉之后的 Tab 切换点击。
    final tabFinder = find.text('Completed (1)');
    expect(tabFinder, findsOneWidget);
    await tester.tap(tabFinder);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);

    // E2：pending 任务的菜单带「置顶」（切回进行中 Tab）。
    final ongoingTab = find.text('Ongoing (1)');
    expect(ongoingTab, findsOneWidget);
    await tester.tap(ongoingTab);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    // 菜单弹出动画在假时钟里要 pump 够 200ms；100ms 步进不够开。
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Pin to top'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
