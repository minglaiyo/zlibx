import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/screens/book_detail/related_booklists_screen.dart';
import 'package:zlibx/services/storage_service.dart';

const _user = User(
  id: '35899435',
  email: 'a@example.com',
  name: 'userA',
  remixUserkey: 'keyA',
);

class _FakeAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(user: _user);
}

/// 记账 fetchBookDetailExtras 与 favorite 两个接口;其余成员命中即抛
/// (面板成功路径还会碰 BooklistHtmlCache——它是未初始化
/// Hive 时静默返回的静态守卫,不需要 fake)。
class _FakeApi implements ZLibraryApi {
  int extrasCalls = 0;
  int favoriteCalls = 0;

  /// true 时抓取返回墙错误(失败态/重试夹具)。
  bool failExtras = false;

  /// 抓取成功时返回的关联书单。
  List<Booklist> lists = const [];

  @override
  Future<ApiResponse<BookDetailExtras>> fetchBookDetailExtras(
    String href,
  ) async {
    extrasCalls++;
    if (failExtras) {
      return ApiResponse.fail('HTTP 513: browser check page');
    }
    return ApiResponse.ok(
      BookDetailExtras(metadata: BookDetailMetadata(), relatedBooklists: lists),
    );
  }

  @override
  Future<ApiResponse<bool>> favoriteBooklist(int id) async {
    favoriteCalls++;
    return ApiResponse.ok(true);
  }

  // 成功路径的收藏页缓存失效会构造该 URL——直接给个够用的常量。
  @override
  String booklistsPageUrl({
    required bool mine,
    bool favorite = false,
    String query = '',
    String? order,
    int page = 1,
  }) => 'https://example.invalid/booklists/favorite?page=$page';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');
}

/// 附加字段缓存替身：不碰 Hive，直接内存 Map（本页测试不带缓存）。
class _FakeStorage extends StorageService {
  @override
  Map<String, dynamic>? getBookDetailExtrasSync(String pagePath) => null;

  @override
  Future<void> mergeBookDetailExtras(
    String pagePath,
    Map<String, dynamic> fields,
  ) async {}
}

/// 抓回来渲染的关联书单(名称/册数都来自书页 HTML 解析结果)。
List<Booklist> _lists() => [
  Booklist(
    id: '498889',
    name: 'Psicologia',
    url: 'https://example.invalid/booklist/498889/f77552/1.html',
    count: 423,
  ),
  Booklist(
    id: '4007439',
    name: 'Personal growth',
    url: 'https://example.invalid/booklist/4007439/2c889e/2.html',
    count: 729,
  ),
];

Widget _host({required Widget home}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeApi api, {
  String href = '/book/hash42/合成书.html',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        zlibraryApiProvider.overrideWithValue(api),
        storageServiceProvider.overrideWithValue(_FakeStorage()),
        authProvider.overrideWith(_FakeAuth.new),
      ],
      child: _host(home: RelatedBooklistsScreen(href: href)),
    ),
  );
}

void main() {
  testWidgets('点进即抓:成功后渲染标题与每单名称、册数', (tester) async {
    final api = _FakeApi()..lists = _lists();
    await _pumpScreen(tester, api);
    await tester.pumpAndSettle();

    expect(api.extrasCalls, 1);
    expect(find.text('关联书单'), findsOneWidget);
    expect(find.text('Psicologia'), findsOneWidget);
    expect(find.text('Personal growth'), findsOneWidget);
    expect(find.text('423 本书'), findsOneWidget);
    expect(find.text('729 本书'), findsOneWidget);
  });

  testWidgets('长按行弹出同款面板;点收藏走收藏接口并提示', (tester) async {
    final api = _FakeApi()..lists = _lists();
    await _pumpScreen(tester, api);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Psicologia'));
    await tester.pumpAndSettle();
    // 面板:标题=书单名,两行=收藏 + 分享。
    expect(find.text('Psicologia'), findsWidgets);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(api.favoriteCalls, 1);
    expect(find.text('已收藏书单'), findsOneWidget);

    // snack 的 2.5s 自动收起计时器必须在测试结束前烧掉。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('抓取失败:失败文案 + 重试,重试成功后渲染', (tester) async {
    final api = _FakeApi()..failExtras = true;
    await _pumpScreen(tester, api);
    await tester.pumpAndSettle();

    expect(api.extrasCalls, 1);
    expect(find.text('关联书单加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试:墙解开了,这次抓取成功并渲染列表。
    api
      ..failExtras = false
      ..lists = _lists();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.extrasCalls, 2);
    expect(find.text('Psicologia'), findsOneWidget);
    expect(find.text('Personal growth'), findsOneWidget);
  });

  testWidgets('书页没有关联书单:空态文案,不弹重试', (tester) async {
    final api = _FakeApi();
    await _pumpScreen(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('这本书还没被收录进任何书单'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}
