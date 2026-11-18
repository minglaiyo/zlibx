import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/screens/book_detail/book_detail_screen.dart';
import 'package:zlibx/screens/book_detail/widgets/book_action_bar.dart';
import 'package:zlibx/screens/book_detail/widgets/book_detail_content.dart';
import 'package:zlibx/screens/book_detail/widgets/book_hero_section.dart';
import 'package:zlibx/screens/book_detail/widgets/book_info_section.dart';
import 'package:zlibx/screens/search/search_screen.dart';

Widget app(Widget body, {Brightness brightness = Brightness.light,
  double scale = 1, Widget? actionBar, Locale locale = const Locale('en')}) => ProviderScope(
  child: MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      // The 3D cover floats forever (AnimationController.repeat), so tests
      // must run with animations disabled or pumpAndSettle can never finish.
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: Scaffold(body: body, bottomNavigationBar: actionBar),
  ),
);

void main() {
  final longText = List.filled(20, 'A long introduction that needs more than six lines.').join('\n');
  const book = Book(id: 7, title: 'A very long title to verify wrapping on a narrow phone',
    author: 'An author with a long name', publisher: 'A publishing house with a long name',
    pages: 300, language: 'English', year: 2026, extension: 'epub',
    filesizeString: '12 MB', hash: 'sample', readOnlineUrl: 'https://example.com/read');
  // Book has no copyWith: build the described variant as a new literal.
  final describedBook = Book(id: book.id, title: book.title,
    author: book.author, publisher: book.publisher, pages: book.pages,
    language: book.language, year: book.year, extension: book.extension,
    filesizeString: book.filesizeString, hash: book.hash,
    readOnlineUrl: book.readOnlineUrl, description: longText);
  testWidgets('short description needs no expansion control', (tester) async {
    await tester.pumpWidget(app(const BookDetailDescription(text: 'Short introduction.')));
    await tester.pumpAndSettle();
    expect(find.text('Short introduction.'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('description expands, collapses, and resets for another book', (tester) async {
    Widget description(String text) => app(SingleChildScrollView(
      child: BookDetailDescription(key: const ValueKey('description'), text: text)));
    await tester.pumpWidget(description(longText));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longText)).maxLines, 6);
    await tester.tap(find.text('Read More'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longText)).maxLines, isNull);
    await tester.ensureVisible(find.text('Show Less'));
    await tester.tap(find.text('Show Less'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longText)).maxLines, 6);
    await tester.ensureVisible(find.text('Read More'));
    await tester.tap(find.text('Read More'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(description('$longText\nNew book.'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('$longText\nNew book.')).maxLines, 6);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('both detail layouts fit a narrow phone: $brightness, $scale', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final section in [
          BookInfoSection(book: describedBook),
        ]) {
          await tester.pumpWidget(app(CustomScrollView(slivers: [section]),
            brightness: brightness, scale: scale));
          await tester.pumpAndSettle();
          expect(find.text(book.title), findsOneWidget);
          expect(find.text(book.author!), findsOneWidget);
          await tester.ensureVisible(find.text('Publication Details'));
          await tester.pumpAndSettle();
          expect(find.text(book.publisher!), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('category chip shows when the detail carries categories',
      (tester) async {
    const categorized = Book(
      id: 7,
      title: 'Categorized book',
      author: 'An author',
      year: 2018,
      extension: 'epub',
      filesizeString: '5.72 MB',
      categories: 'Fiction - Horror',
      hash: 'sample',
    );
    await tester.pumpWidget(app(
      CustomScrollView(slivers: const [BookInfoSection(book: categorized)]),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Fiction - Horror'), findsOneWidget);
    expect(find.text('2018'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('category chip is localized for the app language',
      (tester) async {
    const categorized = Book(
      id: 7,
      title: 'Categorized book',
      author: 'An author',
      year: 2014,
      extension: 'epub',
      filesizeString: '2.12 MB',
      categories: '{307: History - World history, 271: Fiction - Horror}',
      hash: 'sample',
    );
    await tester.pumpWidget(app(
      CustomScrollView(slivers: const [BookInfoSection(book: categorized)]),
      locale: const Locale('zh'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('世界历史'), findsOneWidget);
    expect(find.text('恐怖'), findsOneWidget);
    expect(find.text('History - World history'), findsNothing);
    expect(find.byIcon(Icons.category_outlined), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a doubled parent word shows once in the category chip',
      (tester) async {
    const categorized = Book(
      id: 7,
      title: 'Categorized book',
      author: 'An author',
      year: 2021,
      extension: 'epub',
      filesizeString: '4.74 MB',
      categories: '{528: Psychology - Psychology - theory, history & research}',
      hash: 'sample',
    );
    await tester.pumpWidget(app(
      CustomScrollView(slivers: const [BookInfoSection(book: categorized)]),
      locale: const Locale('zh'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('心理学：理论、历史与研究'), findsOneWidget);
    expect(find.text('心理学 - 心理学：理论、历史与研究'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no category chip when the detail carries none',
      (tester) async {
    await tester.pumpWidget(app(
      CustomScrollView(slivers: [BookInfoSection(book: book)]),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.category_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero reveals the toolbar title after scrolling', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(CustomScrollView(controller: controller, slivers: const [
      BookHeroSection(book: DisplayBook(id: '7', title: 'Scroll title', source: BookSource.zlibrary),
        isFavorited: false),
      SliverToBoxAdapter(child: SizedBox(height: 1500)),
    ])));
    await tester.pumpAndSettle();
    Finder opacity() => find.ancestor(of: find.text('Scroll title'), matching: find.byType(AnimatedOpacity));
    expect(tester.widget<AnimatedOpacity>(opacity()).opacity, 0);
    controller.jumpTo(300);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(opacity()).opacity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('action bar fits large text and disables an active download', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(const SizedBox(), scale: 2,
      actionBar: const BookActionBar(book: book,
        downloadTask: DownloadTask(id: '7', book: book, progress: .42,
          status: DownloadStatus.downloading), isDownloading: true, isCompleted: false)));
    await tester.pumpAndSettle();
    expect(find.text('42%'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNull);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  // The author/publisher taps navigate to the search page carrying
  // the tapped name as the query (the search screen pre-fills it and
  // runs it). The route generator captures the pushed arguments; the
  // dummy page stands in for the real search screen.
  testWidgets('tapping the author opens the author aggregation page',
      (tester) async {
    // 方案 F2：作者点击 → /author/{名} 聚合页（作者串原样传参）；
    // 聚合页空态里才有"按作者搜索"回退。
    String? pushedAuthor;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          onGenerateRoute: (settings) {
            if (settings.name == '/author' &&
                settings.arguments is String &&
                (settings.arguments as String).isNotEmpty) {
              pushedAuthor = settings.arguments as String;
            }
            return MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('author')),
            );
          },
          home: Scaffold(
            body: CustomScrollView(
              slivers: [BookInfoSection(book: book)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(book.author!));
    await tester.pumpAndSettle();
    expect(pushedAuthor, book.author);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the publisher opens a search for that publisher',
      (tester) async {
    SearchScreenArgs? pushed;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          onGenerateRoute: (settings) {
            if (settings.arguments is SearchScreenArgs) {
              pushed = settings.arguments as SearchScreenArgs;
            }
            return MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('search')),
            );
          },
          home: Scaffold(
            body: CustomScrollView(
              slivers: [BookInfoSection(book: book)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(book.publisher!));
    await tester.pumpAndSettle();
    await tester.tap(find.text(book.publisher!));
    await tester.pumpAndSettle();
    expect(pushed, isNotNull);
    expect(pushed!.query, book.publisher);
    expect(pushed!.categoryId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('IPFS CID rows copy their own CID on tap', (tester) async {
    const ipfsBook = Book(
      id: 9,
      title: 'Book with IPFS CIDs',
      author: 'An author',
      year: 2020,
      extension: 'pdf',
      filesizeString: '1 MB',
      hash: 'sample',
      ipfsCid: 'QmPrimaryCidValue',
      ipfsCidBlake2b: 'bafkBlake2bCidValue',
    );
    // Clipboard 是平台通道，测试里用 mock 处理器截住写入值。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(app(
      CustomScrollView(slivers: [BookInfoSection(book: ipfsBook)]),
    ));
    await tester.pumpAndSettle();

    // 两行 CID 各自成行（此前是一格塞两行、不可复制）。
    expect(find.text('QmPrimaryCidValue'), findsOneWidget);
    expect(find.text('bafkBlake2bCidValue'), findsOneWidget);

    // 点主 CID 行：复制主 CID，弹已复制提示。
    await tester.tap(find.text('QmPrimaryCidValue'));
    await tester.pumpAndSettle();
    expect(copied, 'QmPrimaryCidValue');
    expect(find.text('Copied to clipboard'), findsOneWidget);

    // Blake2b 行复制的是自己的值，不是主 CID。
    await tester.ensureVisible(find.text('bafkBlake2bCidValue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bafkBlake2bCidValue'));
    await tester.pumpAndSettle();
    expect(copied, 'bafkBlake2bCidValue');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a book without IPFS CIDs shows no CID rows', (tester) async {
    await tester.pumpWidget(app(
      CustomScrollView(slivers: [BookInfoSection(book: book)]),
    ));
    await tester.pumpAndSettle();
    expect(find.text('IPFS'), findsNothing);
    expect(find.text('CID Blake2b'), findsNothing);
  });
  // 详情页要渲染的书本体 = 入参→eapi→附加字段，逐层覆盖。
  // 2026-11-15 提速后附加字段是独立的一条腿：正文必须在它到达
  // 之前就是完整的，到达后再补上卷/ISBN/评分。
  group('bookDetailPayload', () {
    final eapiBook = Book(
      id: 7,
      title: 'A very long title to verify wrapping on a narrow phone',
      author: 'eapi 作者',
      description: 'eapi 简介',
      filesizeString: '9 MB',
      hash: 'sample',
      href: '/book/sample/7.html',
    );
    const extras = {'volume': '第一卷', 'ratingInterest': '3.0'};

    test('eapi 未到：用入参书本体', () {
      final payload = bookDetailPayload(
        initialBook: book,
        details: const AsyncValue<Book>.loading(),
        extras: null,
      );
      expect(payload.author, book.author);
      expect(payload.volume, isNull);
    });

    test('eapi 已到、附加字段未到：正文已完整', () {
      final payload = bookDetailPayload(
        initialBook: book,
        details: AsyncValue<Book>.data(eapiBook),
        extras: null,
      );
      expect(payload.author, 'eapi 作者');
      expect(payload.description, 'eapi 简介');
      expect(payload.volume, isNull);
    });

    test('附加字段后到：只补行，不抹 eapi 已有的字段', () {
      final payload = bookDetailPayload(
        initialBook: book,
        details: AsyncValue<Book>.data(eapiBook),
        extras: extras,
      );
      expect(payload.volume, '第一卷');
      expect(payload.ratingInterest, '3.0');
      expect(payload.author, 'eapi 作者');
      // 附加字段里没有的列（值为 null）不许抹掉 eapi 已有的。
      expect(payload.filesizeString, '9 MB');
      expect(payload.ratingQuality, isNull);
    });

    test('附加字段缺失时评分用 eapi interestScore 兜底', () {
      final withScore = Book(
        id: 7,
        title: book.title,
        interestScore: '4.2',
        hash: 'sample',
      );
      expect(
        bookDetailPayload(
          initialBook: withScore,
          details: AsyncValue<Book>.data(withScore),
          extras: null,
        ).ratingInterest,
        '4.2',
      );
      // HTML 的评分到了就归它说了算。
      expect(
        bookDetailPayload(
          initialBook: withScore,
          details: AsyncValue<Book>.data(withScore),
          extras: extras,
        ).ratingInterest,
        '3.0',
      );
    });
  });
}
