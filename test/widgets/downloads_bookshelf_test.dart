// 下载页「已完成」Tab 的书架网格：封面 + 书名 + 作者·格式，点书进
// in-app 阅读器。导航用 onGenerateRoute 拦截 '/local-reader'，
// 只记录参数、不真起 WebView（WebView 的启动由
// local_reader_server_test 覆盖）。PDF 不进阅读器，走外部打开。
//
// FakeAsync 区的教训（#515/#516：EPUB 测试两次 10 分钟超时）：
// testWidgets 体内跑在 FakeAsync 区，真实磁盘 IO 的 Future
// 永远不完成——EPUB 测试挂在第一行 makeBook（File.writeAsBytes），
// 跟 pumpAndSettle 无关（d31bc94 把 8 处 pumpAndSettle 换成定步进
// pump 后 #516 照样超时）。所以：
//   - 文件一律在 setUp（真实区）里建好，体内只用现成路径；
//   - 点卡片后触发的文件存在检查同样是真实 IO，用 runAsync
//     切到真实区驱动（见 pumpForNavigation / PDF 测试里的
//     runAsync），光 pump 等不到它。
// 同目录 downloads_category_filter_test 的文件头有同样的教训
// （Hive put 落盘 Future 不完成）。
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
  late String epubPath;
  late String txtPath;
  late String notesTxtPath;
  late String pdfPath;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('downloads_bookshelf');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir!.delete(recursive: true);
  });

  Future<String> makeBook(String name, List<int> bytes) async {
    final file = File('${filesDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  setUp(() async {
    filesDir = await Directory.systemTemp.createTemp('bookshelf_files');
    pushedArgs = null;
    // 真实区：文件在这里建好；testWidgets 体内（FakeAsync 区）
    // 写文件永远不完成（见文件头注释），所以体内只用现成路径。
    epubPath = await makeBook('one.epub', [0x50, 0x4B, 0x03, 0x04]);
    txtPath = await makeBook('two.txt', [0x68, 0x69]);
    notesTxtPath = await makeBook('notes.txt', [0x68, 0x69]);
    pdfPath = await makeBook('doc.pdf', [0x25, 0x50, 0x44, 0x46]);
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

  /// 定步进 settle，替代 pumpAndSettle：Tab 切换动画 300ms，
  /// 5×100ms 足够走完；即使个别动画/定时器一直排帧，有限次数
  /// 的 pump 也不会把测试挂住。
  Future<void> pumpSettled(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 点卡片后等导航落定：openLocalReaderForTask 先 await 真实文件
  /// 存在检查（File.exists）。真实磁盘 IO 在 FakeAsync 区里不
  /// 完成，光 pump 等不到它；每次 runAsync 用真实延时让出事件
  /// 循环，IO 完成后外层排空 fake 微任务，导航的 pushNamed 得以
  /// 执行；再 pump 一帧建出路由。最多 10×100ms 真实时间。
  Future<void> pumpForNavigation(WidgetTester tester) async {
    for (var i = 0; i < 10 && pushedArgs == null; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
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
    await pumpForNavigation(tester);
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
    await tester.pumpWidget(
      app(
        overridesFor({'3': _task('3', 'Txt notes', 'txt', notesTxtPath)}),
      ),
    );
    await pumpSettled(tester);
    await tester.tap(find.text('Completed (1)'));
    await pumpSettled(tester);

    await tester.tap(find.text('Txt notes'));
    await pumpForNavigation(tester);
    await tester.pump();
    expect(pushedArgs, isNotNull);
    expect(pushedArgs!.filePath, notesTxtPath);
    expect(pushedArgs!.bookKey, '3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点 PDF 不进阅读器', (tester) async {
    await tester.pumpWidget(
      app(
        overridesFor({'4': _task('4', 'Pdf doc', 'pdf', pdfPath)}),
      ),
    );
    await pumpSettled(tester);
    await tester.tap(find.text('Completed (1)'));
    await pumpSettled(tester);

    await tester.tap(find.text('Pdf doc'));
    // PDF 不进阅读器：外部打开链同样先 await 真实文件存在检查，
    // 用一次 runAsync 让它跑完（平台通道异常被接住弹提示），
    // 再定步进 pump。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
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
