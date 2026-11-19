import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklist_detail_provider.dart';
import 'package:zlibx/screens/account/booklist_detail_screen.dart';

/// 书单详情页(2026-11-19 整体重设计,视觉稿 ③)的渲染冒烟:视差
/// 头图(模糊底/堆叠封面/白字书名)、玻璃胶囊行、作者 chip、搜索
/// 排序行、封面网格必须全部渲染且不抛——新布局从没在真机截图核对
/// 过之前,这条测试就是它的开机自检。
class _FakeDetailController extends BooklistDetailController {
  _FakeDetailController(this._state);

  final BooklistDetailState _state;

  @override
  BooklistDetailState build(BooklistDetailArgs arg) => _state;

  @override
  Future<void> loadFirst() async {}

  @override
  Future<void> loadMore() async {}
}

Booklist _booklist() => Booklist(
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

List<Book> _books() => [
  Book(id: 11, title: '心流+发现心流 (套装全2册)', author: '契克森米哈赖', year: 2018,
      cover: 'https://example.invalid/b1.jpg'),
  Book(id: 12, title: '怪癖心理学', author: '冈田尊司', year: 2020,
      cover: 'https://example.invalid/b2.jpg'),
  Book(id: 13, title: '人是什么', author: '朱建军', year: 2015,
      cover: 'https://example.invalid/b3.jpg'),
  Book(id: 14, title: '当下的力量', author: '埃克哈特·托利', year: 2019,
      cover: 'https://example.invalid/b4.jpg'),
];

Future<void> _pump(
  WidgetTester tester, {
  required BooklistDetailState state,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Notifier family 的 override 是零参构造;build(arg) 自己收参。
        booklistDetailControllerProvider.overrideWith(
          () => _FakeDetailController(state),
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
        home: BooklistDetailScreen(
          args: BooklistDetailArgs(booklist: _booklist()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('头图/胶囊/作者行/搜索排序/网格全渲染且不抛', (tester) async {
    await _pump(
      tester,
      state: BooklistDetailState(
        isLoading: false,
        books: _books(),
        hasMore: false,
      ),
    );

    // 书名:视差头图白字 + AppBar 折叠标题,至少都出现。
    expect(find.text('自我疗愈'), findsWidgets);
    // 玻璃胶囊:收藏态文案 + 分享。
    expect(find.text('已收藏书单'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    // 作者 chip 行(头像 + 作者 · 册数 · 浏览量)。
    expect(find.textContaining('78 本书'), findsOneWidget);
    // 搜索行在;书籍网格的书名可见。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('心流+发现心流 (套装全2册)'), findsOneWidget);
    expect(find.text('当下的力量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('客户端排序切换与搜索过滤只动本地数据', (tester) async {
    await _pump(
      tester,
      state: BooklistDetailState(
        isLoading: false,
        books: _books(),
        hasMore: false,
      ),
    );

    // 默认从新到旧:2020 → 2019 → 2018 → 2015。直接断言网格卡片的
    // 构建顺序(与布局无关)。
    List<String> gridTitles() => tester
        .widgetList<BooklistShelfTile>(find.byType(BooklistShelfTile))
        .map((c) => c.book.title)
        .toList();
    expect(
      gridTitles(),
      ['怪癖心理学', '当下的力量', '心流+发现心流 (套装全2册)', '人是什么'],
    );

    await tester.tap(find.text('最新创建'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(gridTitles(), [
      '人是什么',
      '心流+发现心流 (套装全2册)',
      '当下的力量',
      '怪癖心理学',
    ]);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '托利');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('当下的力量'), findsOneWidget);
    expect(find.text('人是什么'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
