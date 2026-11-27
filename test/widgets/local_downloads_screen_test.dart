// P2-6: LocalDownloadsScreen 屏幕级三态。只拼已验证的套子:假的
// DownloadNotifier(直接回整态任务列表,绕开真实引擎/历史恢复)+
// 假的 ShelfCategoriesNotifier(空分类树)。屏幕本身只 watch
// downloadListStructureProvider(由 downloadProvider 派生),行按
// downloadTaskProvider 取任务;已完成页的分类条只读假分类树。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/providers/shelf_categories_provider.dart';
import 'package:zlibx/screens/downloads/local_downloads_screen.dart';

class _FakeDownloadNotifier extends DownloadNotifier {
  _FakeDownloadNotifier(this._tasks);

  final List<DownloadTask> _tasks;

  @override
  List<DownloadTask> build() => _tasks;
}

class _FakeShelfCategories extends ShelfCategoriesNotifier {
  @override
  ShelfCategoriesState build() => const ShelfCategoriesState([], {});
}

DownloadTask _task(
  String id,
  String title, {
  required DownloadStatus status,
  DateTime? downloadedAt,
}) => DownloadTask(
  id: id,
  book: Book(id: int.parse(id), title: title, author: 'A'),
  status: status,
  downloadedAt: downloadedAt,
  fileSize: 1024,
);

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    required List<DownloadTask> tasks,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadProvider.overrideWith(() => _FakeDownloadNotifier(tasks)),
          shelfCategoriesProvider.overrideWith(
            () => _FakeShelfCategories(),
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
          home: const LocalDownloadsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('空态显示没有进行中的下载', (tester) async {
    await pumpScreen(tester, tasks: const []);

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('进行中 (0)'), findsOneWidget);
    expect(find.text('已完成 (0)'), findsOneWidget);
    expect(find.text('没有正在进行的下载'), findsOneWidget);
    expect(find.text('下载内容将显示在这里'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进行中列表显示任务标题与计数', (tester) async {
    await pumpScreen(
      tester,
      tasks: [
        _task('1', 'One', status: DownloadStatus.downloading),
      ],
    );

    expect(find.text('进行中 (1)'), findsOneWidget);
    expect(find.text('已完成 (0)'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到已完成页显示任务与今天分组头', (tester) async {
    await pumpScreen(
      tester,
      tasks: [
        _task(
          '2',
          'Two',
          status: DownloadStatus.completed,
          downloadedAt: DateTime.now(),
        ),
      ],
    );

    expect(find.text('已完成 (1)'), findsOneWidget);
    await tester.tap(find.text('已完成 (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
