// 下载页「已完成」Tab 的书架网格：封面 + 书名 + 作者·格式，点书进
// in-app 阅读器。导航用 onGenerateRoute 拦截 '/local-reader'，
// 只记录参数、不真起 WebView（WebView 的启动由
// local_reader_server_test 覆盖）。PDF 不进阅读器，走外部打开。
//
// #515 教训：本文件原来全程用 pumpAndSettle，Check 里 EPUB 测试
// 10 分钟超时、之后测试运行器再无输出（Test 步 19m21s 后被取消）。
// 同目录 downloads_category_filter_test 早有同样教训（pending 行
// 的不确定进度条让 pumpAndSettle 永不结束），所以本文件也全程用
// 定步进 pump（见下面的 pumpSettled），不给任何动画/定时器挂住
// 测试的机会；点卡片后的导航等待同样定次数上限。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/screens/downloads/local_downloads_screen.dart';
import 'package:zlibx/screens/reader/local_reader_screen.dart';
import 'package:zlibx/services/hive_service.dart';

DownloadTask _task(
  String id,
  String title,
  String extension,
  String filePath,
) => DownloadTask(
  id: id,
  book: Book(
    id: int.parse(id),
    title: title,
    author: 'Author $id',
    extension: extension,
  ),
  status: DownloadStatus.completed,
  downloadedAt: DateTime(2026, 11, 18, 10),
  fileSize: 2048,
  filePath: filePath,
);

void main() {
  Directory? hiveDir;
  late Directory filesDir;
  LocalReaderArgs? pushedArgs;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('downloads_bookshelf');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir!.delete(recursive: true);
  });

  setUp(() async {
    filesDir = await Directory.systemTemp.createTemp('bookshelf_files');
    pushedArgs = null;
  });

  tearDown(() async {
    await filesDir.delete(recursive: true);
  });

  Widget app(List<Override> overrides) => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      onGenerateRoute: (settings) {
        if (settings.name == '/local-reader') {
          pushedArgs = settings.arguments as LocalReaderArgs?;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Center(child: Text('mock reader')),
            ),
          );
        }
        return MaterialPageRoute<void>(
          builder: (_) => const LocalDownloadsScreen(),
        );
      },
    ),
  );

  Future<String> makeBook(String name, List<int> bytes) async {
    final file = File('${filesDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 定步进 settle，替代 pumpAndSettle：Tab 切换动画 300ms，
  /// 5×100ms 足够走完；即使个别动画/定时器一直排帧，有限次数
  /// 的 pump 也不会把测试挂住（#515 的 EPUB 测试就是被
  /// pumpAndSettle 挂了 10 分钟超时）。
  Future<void> pumpSettled(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  List<Override> overridesFor(Map<String, DownloadTask> tasks) => [
    downloadListStructureProvider.overrideWithValue(
      DownloadListStructure(
        ongoingIds: [],
        completedIds: tasks.keys.toList(),
        completedDates: {
          for (final id in tasks.keys) id: DateTime(2026, 11, 18, 10),
        },
      ),
    ),
    for (final entry in tasks.entries)
      downloadTaskProvider(entry.key).overrideWithValue(entry.value),
  ];

  testWidgets('已完成 Tab 是书架网格，点 EPUB 进阅读器', (tester) async {
    final epubPath = await makeBook('one.epub', [0x50, 0x4B, 0x03, 0x04]);
    final txtPath = await makeBook('two.txt', [0x68, 0x69]);
    await tester.pumpWidget(
      app(
        overridesFor({
          '1': _task('1', 'Epub book', 'epub', epubPath),
          '2': _task('2', 'Txt book', 'txt', txtPath),
        }),
      ),
    );
    await pumpSettled(tester);

    await tester.tap(find.text('Completed (2)'));
    await pumpSettled(tester);

    // 书架网格：书名、作者·格式都在卡片上；列表行的状态标签不在。
    expect(find.text('Epub book'), findsOneWidget);
    expect(find.text('Txt book'), findsOneWidget);
    expect(find.text('Author 1 · EPUB'), findsOneWidget);
    expect(find.text('Author 2 · TXT'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);

    // 点 EPUB 卡片：进 /local-reader，带真实路径与任务 id。
    await tester.tap(find.text('Epub book'));
    // 点卡片后 openLocalReaderForTask 先 await 文件存在检查（真实
    // IO），再 pushNamed；定次数 pump 等导航落定（最多 10×100ms），
    // 导航一到就停，不用 pumpAndSettle。
    for (var i = 0; i < 10 && pushedArgs == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 路由已 push，再 pump 一帧把它建出来。
    await tester.pump();
    expect(pushedArgs, isNotNull);
    expect(pushedArgs!.filePath, epubPath);
    expect(pushedArgs!.bookKey, '1');
    expect(pushedArgs!.title, 'Epub book');
    expect(find.text('mock reader'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点 TXT 也进阅读器（转换在服务器里做）', (tester) async {
    final txtPath = await makeBook('notes.txt', [0x68, 0x69]);
    await tester.pumpWidget(
      app(
        overridesFor({'3': _task('3', 'Txt notes', 'txt', txtPath)}),
      ),
    );
    await pumpSettled(tester);
    await tester.tap(find.text('Completed (1)'));
    await pumpSettled(tester);

    await tester.tap(find.text('Txt notes'));
    // 同 EPUB：定次数 pump 等导航落定（最多 10×100ms）。
    for (var i = 0; i < 10 && pushedArgs == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(pushedArgs, isNotNull);
    expect(pushedArgs!.filePath, txtPath);
    expect(pushedArgs!.bookKey, '3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点 PDF 不进阅读器', (tester) async {
    final pdfPath = await makeBook('doc.pdf', [0x25, 0x50, 0x44, 0x46]);
    await tester.pumpWidget(
      app(
        overridesFor({'4': _task('4', 'Pdf doc', 'pdf', pdfPath)}),
      ),
    );
    await pumpSettled(tester);
    await tester.tap(find.text('Completed (1)'));
    await pumpSettled(tester);

    await tester.tap(find.text('Pdf doc'));
    // PDF 不进阅读器：定步进 pump 让外部打开的异步链跑完即可。
    await pumpSettled(tester);
    // 没进 /local-reader（外部打开走平台通道，测试里被接住）。
    expect(pushedArgs, isNull);
    expect(find.text('mock reader'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成为空时显示空状态', (tester) async {
    await tester.pumpWidget(app(overridesFor({})));
    await pumpSettled(tester);
    await tester.tap(find.text('Completed (0)'));
    await pumpSettled(tester);
    expect(find.byType(GridView), findsNothing);
    expect(find.textContaining('No completed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
