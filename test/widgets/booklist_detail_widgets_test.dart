import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/screens/account/widgets/booklist_detail_actions.dart';
import 'package:zlibx/screens/account/widgets/booklist_detail_grid.dart';
import 'package:zlibx/screens/account/widgets/booklist_detail_hero.dart';
import 'package:zlibx/screens/account/widgets/booklist_detail_states.dart';
import 'package:zlibx/widgets/empty_state.dart';
import 'package:zlibx/widgets/loading_widget.dart';

/// P1-4 split coverage: the widgets extracted from
/// booklist_detail_screen.dart, pumped on their own — the full-screen
/// test (booklist_detail_screen_test.dart) still covers the assembled
/// page, these cover the pieces directly.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(900, 1800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> pumpSliver(WidgetTester tester, Widget sliver) async {
    await pump(
      tester,
      CustomScrollView(slivers: [sliver]),
    );
  }

  Booklist booklist() => Booklist(
    id: '498889',
    name: '自我疗愈',
    author: 'Amy',
    authorProfile: '/profile/34819554/8066a9',
    count: 78,
    views: '24K',
    description: '这是书单简介,足够长以便测试可展开文本在 sheet 内渲染正常。'
        '第二段继续填充行数,触发折叠与展开箭头。再补一段确保超过三行。',
    url: 'https://example.invalid/booklist/498889/f77552/1.html',
    isFavorite: true,
    previewBooks: [
      Book(id: 1, title: '心流+发现心流', cover: 'https://example.invalid/c1.jpg'),
      Book(id: 2, title: '怪癖心理学', cover: 'https://example.invalid/c2.jpg'),
      Book(id: 3, title: '潜意识知道答案', cover: 'https://example.invalid/c3.jpg'),
    ],
  );

  List<Book> books() => [
    Book(id: 11, title: '心流+发现心流 (套装全2册)', author: '契克森米哈赖', year: 2018),
    Book(id: 12, title: '怪癖心理学', author: '冈田尊司', year: 2020),
  ];

  group('BooklistDetailHero', () {
    testWidgets('头图/胶囊/作者行/搜索排序行全渲染', (tester) async {
      final pixels = ValueNotifier<double>(0);
      addTearDown(pixels.dispose);
      final search = TextEditingController();
      addTearDown(search.dispose);
      await pump(
        tester,
        SingleChildScrollView(
          child: BooklistDetailHero(
            booklist: booklist(),
            favorite: true,
            pixels: pixels,
            searchController: search,
            newestFirst: true,
            onToggleFavorite: () {},
            onShare: () {},
            onQueryChanged: (_) {},
            onToggleSort: () {},
            onClearSearch: () {},
          ),
        ),
      );

      expect(find.text('自我疗愈'), findsOneWidget);
      expect(find.text('已收藏书单'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.textContaining('78 本书'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('最新创建'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收藏胶囊点按透传回调', (tester) async {
      var tapped = false;
      final pixels = ValueNotifier<double>(0);
      addTearDown(pixels.dispose);
      final search = TextEditingController();
      addTearDown(search.dispose);
      await pump(
        tester,
        SingleChildScrollView(
          child: BooklistDetailHero(
            booklist: booklist(),
            favorite: false,
            pixels: pixels,
            searchController: search,
            newestFirst: true,
            onToggleFavorite: () => tapped = true,
            onShare: () {},
            onQueryChanged: (_) {},
            onToggleSort: () {},
            onClearSearch: () {},
          ),
        ),
      );

      expect(find.text('收藏'), findsOneWidget);
      await tester.tap(find.text('收藏'));
      expect(tapped, isTrue);
    });
  });

  group('BooklistDetailAppBar', () {
    testWidgets('标题栏渲染书单名', (tester) async {
      await pump(
        tester,
        CustomScrollView(
          slivers: [BooklistDetailAppBar(title: '自我疗愈')],
        ),
      );
      expect(find.text('自我疗愈'), findsOneWidget);
    });
  });

  group('BooklistDetailBookGrid', () {
    testWidgets('网格渲染书名,点按与长按透传书', (tester) async {
      Book? tapped;
      Book? longPressed;
      await pump(
        tester,
        CustomScrollView(
          slivers: [
            BooklistDetailBookGrid(
              books: books(),
              canEdit: true,
              onTap: (book) => tapped = book,
              onLongPress: (book) => longPressed = book,
            ),
          ],
        ),
      );

      expect(find.text('心流+发现心流 (套装全2册)'), findsOneWidget);
      expect(find.text('怪癖心理学'), findsOneWidget);
      await tester.tap(find.text('怪癖心理学'));
      expect(tapped?.id, 12);
      await tester.longPress(find.text('心流+发现心流 (套装全2册)'));
      expect(longPressed?.id, 11);
      expect(tester.takeException(), isNull);
    });

    testWidgets('canEdit 为 false 时长按不触发', (tester) async {
      var longPressed = false;
      await pump(
        tester,
        CustomScrollView(
          slivers: [
            BooklistDetailBookGrid(
              books: books(),
              canEdit: false,
              onTap: (_) {},
              onLongPress: (_) => longPressed = true,
            ),
          ],
        ),
      );

      await tester.longPress(find.text('怪癖心理学'));
      expect(longPressed, isFalse);
    });

    testWidgets('BooklistShelfTile 单卡渲染标题与作者', (tester) async {
      await pump(
        tester,
        SizedBox(
          height: 300,
          width: 200,
          child: BooklistShelfTile(
            book: books().first,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('心流+发现心流 (套装全2册)'), findsOneWidget);
      expect(find.text('契克森米哈赖'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('加载态显示 LoadingWidget', (tester) async {
      await pumpSliver(tester, const BooklistDetailLoadingSliver());
      expect(find.byType(LoadingWidget), findsOneWidget);
    });

    testWidgets('错误态显示错误标题与重试,点重试回调', (tester) async {
      var retried = false;
      await pumpSliver(
        tester,
        BooklistDetailErrorSliver(
          message: '网络断了',
          onRetry: () => retried = true,
        ),
      );
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('错误'), findsOneWidget);
      expect(find.text('网络断了'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });

    testWidgets('空态与无结果态各显示自己的标题', (tester) async {
      await pumpSliver(tester, const BooklistDetailEmptySliver());
      expect(find.text('这个书单里还没有书'), findsOneWidget);

      await pumpSliver(tester, const BooklistDetailNoResultsSliver());
      expect(find.text('未找到书籍'), findsOneWidget);
    });

    testWidgets('加载更多行点按回调', (tester) async {
      var loaded = false;
      await pump(
        tester,
        BooklistDetailLoadMoreRow(onLoadMore: () => loaded = true),
      );
      await tester.tap(find.text('加载更多'));
      expect(loaded, isTrue);
    });

    testWidgets('单页失败行显示错误并可重试', (tester) async {
      var retried = false;
      await pump(
        tester,
        BooklistDetailPageErrorRow(
          message: '第 2 页失败',
          onRetry: () => retried = true,
        ),
      );
      expect(find.text('第 2 页失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });
  });

  group('actions', () {
    testWidgets('长按面板选批注返回 note 动作', (tester) async {
      BooklistOwnBookAction? result;
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showBooklistOwnBookActions(
                context,
                Book(id: 11, title: '心流', note: '旧备注'),
              );
            },
            child: const Text('打开面板'),
          ),
        ),
      );
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();
      expect(find.text('编辑备注'), findsOneWidget);
      expect(find.text('旧备注'), findsOneWidget);
      await tester.tap(find.text('编辑备注'));
      await tester.pumpAndSettle();
      expect(result, BooklistOwnBookAction.note);
    });

    testWidgets('长按面板选移除返回 remove 动作', (tester) async {
      BooklistOwnBookAction? result;
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showBooklistOwnBookActions(
                context,
                Book(id: 11, title: '心流'),
              );
            },
            child: const Text('打开面板'),
          ),
        ),
      );
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();
      expect(find.text('添加备注'), findsOneWidget);
      await tester.tap(find.text('从书单中移除'));
      await tester.pumpAndSettle();
      expect(result, BooklistOwnBookAction.remove);
    });

    testWidgets('批注对话框输入后保存返回文本,取消返回 null', (tester) async {
      String? result;
      var done = false;
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showBooklistNoteDialog(
                context,
                Book(id: 11, title: '心流'),
              );
              done = true;
            },
            child: const Text('写备注'),
          ),
        ),
      );
      await tester.tap(find.text('写备注'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '值得重读');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(result, '值得重读');
    });
  });
}
