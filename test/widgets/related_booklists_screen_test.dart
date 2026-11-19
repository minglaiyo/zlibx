import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/screens/book_detail/related_booklists_screen.dart';

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

/// 只记账 favorite/unfavorite 两个写接口;其余成员命中即抛
/// (面板成功路径还会碰 BooklistHtmlCache——它是未初始化
/// Hive 时静默返回的静态守卫,不需要 fake)。
class _FakeApi implements ZLibraryApi {
  int favoriteCalls = 0;

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

/// 关联书单落地页：标题 + BooklistRow 列表（名称/册数都来自
/// 路由带的 Booklist，无再请求）。封面留空走占位分支，不触网。
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

void main() {
  testWidgets('列表页渲染标题与每单名称、册数', (tester) async {
    await tester.pumpWidget(
      _host(home: RelatedBooklistsScreen(booklists: _lists())),
    );

    expect(find.text('关联书单'), findsOneWidget);
    expect(find.text('Psicologia'), findsOneWidget);
    expect(find.text('Personal growth'), findsOneWidget);
    expect(find.text('423 本书'), findsOneWidget);
    expect(find.text('729 本书'), findsOneWidget);
  });

  testWidgets('长按行弹出同款面板;点收藏走收藏接口并提示', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          zlibraryApiProvider.overrideWithValue(api),
          authProvider.overrideWith(_FakeAuth.new),
        ],
        child: _host(home: RelatedBooklistsScreen(booklists: _lists())),
      ),
    );

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
}
