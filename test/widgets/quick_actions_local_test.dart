import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/services/annas_models.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/widgets/book_quick_actions_sheet.dart';

/// 快捷面板的外源书「收藏到本地」（方案 C2）：Anna/LibGen 书此前不弹
/// 面板，现在有唯一的落点动作。
///
/// Hive 纪律（两次挂死换来的）：testWidgets 的 FakeAsync 区里测试体
/// 绝不能 await Hive 写操作（clear/put 的真实文件 I/O 完成事件进不了
/// 假时钟区，future 永不完成，用例挂满超时）——种子写放 setUpAll，
/// 断言走内存 get；widget 回调里的 put（如 setEnabled）随它挂，内存
/// 值立即可见、不影响断言。tearDown 不 await close（见
/// settings_privacy_incognito_test）。
Directory? hiveDir;

void main() {
  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('quick_actions_local');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() {
    unawaited(Hive.close());
  });

  DisplayBook annaBook(String md5) => DisplayBook(
    id: md5,
    title: 'An external book',
    author: 'Author',
    source: BookSource.annasArchive,
    original: BookData(
      title: 'An external book',
      link: '/md5/$md5',
      md5: md5,
      info: 'EPUB',
    ),
  );

  Widget app(DisplayBook book) => ProviderScope(
    child: MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showBookQuickActionsSheet(context, book),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('外部源书：未收藏时「收藏到本地」，收藏后变「移出」', (tester) async {
    await tester.pumpWidget(app(annaBook('aa11bb22')));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Save to local collection'), findsOneWidget);

    // 点按 → 内存态更新 + 提示。提示排在 await add 之后，而 add 的
    // Hive put 落盘 Future 在假时钟区永不完成——用 runAsync 给真实
    // I/O 开一个窗口让它跑完，再回假时钟区弹提示。
    await tester.tap(find.text('Save to local collection'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saved to local collection'), findsOneWidget);
    // put 已在 runAsync 窗口里真正落盘，内存值立即可读。
    final raw =
        HiveService.settingsBox.get('external_collection_v1') as String?;
    expect(raw, isNotNull);
    expect(raw!, contains('aa11bb22'));

    // 同一本书再开面板：状态已变，菜单切换为移出。
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from local collection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('z 站书：不出现「收藏到本地」', (tester) async {
    const zBook = DisplayBook(
      id: '5',
      title: 'A z-library book',
      source: BookSource.zlibrary,
      original: Book(id: 5, title: 'A z-library book'),
    );
    await tester.pumpWidget(app(zBook));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Save to local collection'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
