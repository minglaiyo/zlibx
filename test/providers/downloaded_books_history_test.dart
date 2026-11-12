import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';

/// [DownloadedBooksNotifier]（云端下载历史）回归测试。
///
/// 历史根源（两段）：
/// 1. 旧实现只读 eapi `/eapi/user/book/downloaded` 第 1 页、进程内只
///    拉一次且无刷新入口；
/// 2. 2026-11-12 用户报告 + 保存的 zh.z-library.sk 下载历史页证实：
///    eapi 列表根本不含其他设备 / 网页端的下载——真正的全账号逐次
///    日志是网站 `/users/downloads`（HTML，50 行/页）。
///
/// 现在的行为：dstats 为权威列表（全量翻页），eapi 列表只补元数据
/// （作者/封面/格式/大小，失败容忍）。这里锁住这套合并与终止逻辑。
class _FakeZLibraryApi implements ZLibraryApi {
  _FakeZLibraryApi({this.dstatsPages, this.metaPages, this.metaTotalPages});

  /// page -> dstats 页解析结果（缺页按空列表处理 = 翻到头）。
  final Map<int, List<Book>>? dstatsPages;

  /// page -> eapi downloaded 元数据页。
  final Map<int, List<Book>>? metaPages;

  /// eapi 响应的 total_pages（null 表示不带 meta）。
  final int? metaTotalPages;

  int dstatsCalls = 0;
  final List<int?> dstatsSeenPages = [];
  int metaCalls = 0;
  final List<int?> metaSeenPages = [];

  /// 置为 true 后 dstats 请求全部失败。
  bool failDstats = false;

  /// 置为 true 后 dstats 请求全部返回浏览器验证墙错误（真实设备上
  /// 镜像拦页面路由时的形态）。
  bool failDstatsWithWall = false;

  /// 置为 true 后 eapi 元数据请求全部失败。
  bool failMeta = false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  String downloadStatsPageUrl({int page = 1}) =>
      'https://fake.test/users/downloads?page=$page';

  @override
  Future<ApiResponse<List<Book>>> getUserDownloadHistoryPage({
    int? page,
  }) async {
    dstatsCalls++;
    dstatsSeenPages.add(page);
    if (failDstats) {
      return ApiResponse.fail('dstats boom', statusCode: 500);
    }
    if (failDstatsWithWall) {
      return ApiResponse.fail('HTTP 503: browser check page',
          statusCode: 503);
    }
    return ApiResponse.ok(dstatsPages?[page] ?? const []);
  }

  @override
  Future<ApiResponse<List<Book>>> getUserDownloaded({
    int? page,
    int? limit,
  }) async {
    metaCalls++;
    metaSeenPages.add(page);
    if (failMeta) {
      return ApiResponse.fail('meta boom', statusCode: 500);
    }
    return ApiResponse.ok(
      metaPages?[page] ?? const [],
      meta: metaTotalPages == null ? null : {'total_pages': metaTotalPages},
    );
  }
}

/// dstats 记录：书 id + 标题 + 下载时刻。
Book _record(int id, String title, DateTime at) => Book(
      id: id,
      title: title,
      href: '/book/hash$id/${Uri.encodeComponent(title)}.html',
      downloadedAt: at,
    );

/// eapi 元数据：作者/封面/格式/大小，无时间戳。
Book _meta(int id, String author) => Book(
      id: id,
      title: '元数据书$id',
      author: author,
      cover: 'https://cover.example/$id.jpg',
      extension: 'epub',
      filesize: 1234,
      filesizeString: '1.2 KB',
    );

/// 无头 solver 误判为"已过墙"的空 503 页：没有 dstats 标记，也没有
/// 验证墙关键字——标题和正文都认不出它是墙页。
const _bare503Html = '''
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><h1>503</h1></body></html>
''';

/// 一条记录的真 dstats 页（结构同 parsers 夹具）。
const _dstatsPageHtml = '''
<html><body><table><tbody>
<tr class="dstats-row" data-item_id="23787383">
  <td class="lg-w-120" style="white-space: nowrap;">
    <span class="hidden-xs">11.11.2026</span>
    <p style="color: var(--gray-7); padding: 0;">21:02</p>
  </td>
  <td class="lg-w-530" style="max-width: 530px;">
    <div class="book-title">
      <a href="/book/abc123def/书甲.html">书甲</a>
    </div>
  </td>
</tr>
</tbody></table></body></html>
''';

/// 真 dstats 页但 0 行（空页）：有 dstats 标记，解析出空列表。
const _dstatsEmptyHtml = '''
<html><body><div class="dstats-content">
<form class="dstats-form"></form></div></body></html>
''';

/// 测试容器里不碰 secure storage：solver 路径会读 authProvider。
class _SignedOutAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoading: false);
}

ProviderContainer _container(_FakeZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(_SignedOutAuth.new),
    ],
  );
  return container;
}

/// 等待 build() 触发的首次拉取落地（与 saved_books_first_load_test
/// 同一写法）。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  test('dstats 为权威列表：逐次记录全部展示，eapi 元数据按 id 叠加', () async {
    final api = _FakeZLibraryApi(
      dstatsPages: {
        1: [
          _record(7, '书甲', DateTime(2026, 11, 11, 21, 2)),
          // 同一本书下载两次 = 两条记录（逐次日志），时间不同。
          _record(7, '书甲', DateTime(2026, 11, 10, 9, 0)),
        ],
        2: [_record(8, '书乙', DateTime(2026, 11, 9, 8, 30))],
        3: [],
      },
      metaPages: {
        1: [_meta(7, '作者甲'), _meta(99, '作者丙')],
      },
      metaTotalPages: 1,
    );
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final books = container.read(downloadedBooksProvider).valueOrNull!;
    // dstats 的 3 条记录都在（同 id 的两条不合并），顺序 = 服务端顺序。
    expect(books.map((b) => b.downloadedAt).toList(), [
      DateTime(2026, 11, 11, 21, 2),
      DateTime(2026, 11, 10, 9, 0),
      DateTime(2026, 11, 9, 8, 30),
    ]);
    // 命中 id=7 的补上元数据；id=8 没有 eapi 记录也不丢。
    expect(books[0].author, '作者甲');
    expect(books[0].cover, 'https://cover.example/7.jpg');
    expect(books[0].extension, 'epub');
    expect(books[1].author, '作者甲');
    expect(books[2].author, isNull);
    expect(books[2].title, '书乙');
    // dstats 翻到空页才停；eapi 按 total_pages 停。
    expect(api.dstatsSeenPages, [1, 2, 3]);
    expect(api.metaSeenPages, [1]);
  });

  test('dstats 空页终止 + 服务端忽略 page（整页重复）按无新记录终止', () async {
    final same = [
      _record(1, '书一', DateTime(2026, 11, 11, 10, 0)),
      _record(2, '书二', DateTime(2026, 11, 11, 9, 0)),
    ];
    final api = _FakeZLibraryApi(
      dstatsPages: {1: same, 2: same, 3: same},
      metaPages: {1: []},
      metaTotalPages: 1,
    );
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final books = container.read(downloadedBooksProvider).valueOrNull!;
    expect(books.length, 2);
    // 第 2 页整页都是已见记录 → 停，不把第 3 页也拉了。
    expect(api.dstatsSeenPages, [1, 2]);
  });

  test('eapi 元数据失败容忍：dstats 记录照常显示（无作者/封面）', () async {
    final api = _FakeZLibraryApi(
      dstatsPages: {
        1: [_record(5, '书五', DateTime(2026, 11, 11, 12, 0))],
      },
    )..failMeta = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final state = container.read(downloadedBooksProvider);
    expect(state.valueOrNull?.length, 1);
    expect(state.valueOrNull!.first.author, isNull);
  });

  test('dstats 失败才是真失败：报 error（eapi 成功也救不了）', () async {
    final api = _FakeZLibraryApi(
      metaPages: {1: [_meta(1, '作者')]},
      metaTotalPages: 1,
    )..failDstats = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    expect(container.read(downloadedBooksProvider), isA<AsyncError>());
  });

  test('静默对账：补进其他设备的新记录；失败时保留已有列表', () async {
    final api = _FakeZLibraryApi(
      dstatsPages: {
        1: [_record(1, '书一', DateTime(2026, 11, 10, 10, 0))],
      },
      metaPages: {1: []},
      metaTotalPages: 1,
    );
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();
    expect(container.read(downloadedBooksProvider).valueOrNull?.length, 1);

    // 另一台设备刚下了一本书：服务端 dstats 变长，页面打开 / 下拉触发
    // 的 silent 对账把它补进来（新记录在前）。
    api.dstatsPages![1] = [
      _record(2, '书二', DateTime(2026, 11, 11, 20, 0)),
      _record(1, '书一', DateTime(2026, 11, 10, 10, 0)),
    ];
    await container
        .read(downloadedBooksProvider.notifier)
        .loadDownloadedBooks(silent: true);
    expect(
      container.read(downloadedBooksProvider).valueOrNull!.map((b) => b.id),
      [2, 1],
    );

    // 对账失败：保留最后已知的好数据，不闪 error。
    api.failDstats = true;
    await container
        .read(downloadedBooksProvider.notifier)
        .loadDownloadedBooks(silent: true);
    final state = container.read(downloadedBooksProvider);
    expect(state.valueOrNull!.map((b) => b.id), [2, 1]);
  });

  test('首次拉取失败：报 error（可重试），不假装成空历史', () async {
    final api = _FakeZLibraryApi()..failDstats = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    expect(container.read(downloadedBooksProvider), isA<AsyncError>());
  });

  test('镜像验证墙：solver 不可用时抛原始墙错误，不把墙页当空历史', () async {
    // 测试环境没有 WebView（guiEnabled=false 时 solver 必返回 null），
    // 锁住回退终点：把原始墙错误抛给 UI（可重试），而不是解析出 0 行。
    WebviewChallengeSolver.guiEnabled = false;
    addTearDown(() => WebviewChallengeSolver.guiEnabled = true);

    final api = _FakeZLibraryApi(
      metaPages: {
        1: [_meta(1, '作者')],
      },
      metaTotalPages: 1,
    )..failDstatsWithWall = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final state = container.read(downloadedBooksProvider);
    expect(state, isA<AsyncError>());
    expect(
      (state as AsyncError).error.toString(),
      contains('browser check page'),
    );
  });

  test('墙页被无头误判为已过墙：解析失败后走可见 solver，拿到真页即加载', () async {
    // 2026-11-12 真机复现：无头 WebView 抓到空 503 页就当自己过关
    // （标题里没有验证墙关键字），可见回退被跳过，解析守卫把原始
    // 503 错抛出来。修法：解析失败不再直接报错，改走一次可见 solver。
    WebviewChallengeSolver.overrideIsSupported = true;
    WebviewChallengeSolver.overrideIsMobile = true;
    WebviewChallengeSolver.guiEnabled = false;
    addTearDown(() {
      WebviewChallengeSolver.overrideIsSupported = null;
      WebviewChallengeSolver.overrideIsMobile = null;
      WebviewChallengeSolver.guiEnabled = true;
      WebviewChallengeSolver.visibleSolverFallback = null;
    });

    // 第 1 次回退（无头路径）：空 503 页；第 2 次（可见升级）：真页；
    // 第 3 次（第 2 页 Dio 照样撞墙）：空的真 dstats 页，翻页到头。
    var fallbackCalls = 0;
    WebviewChallengeSolver.visibleSolverFallback = (url) async {
      fallbackCalls++;
      if (fallbackCalls == 1) return _bare503Html;
      if (fallbackCalls == 2) return _dstatsPageHtml;
      return _dstatsEmptyHtml;
    };

    final api = _FakeZLibraryApi(
      metaPages: {1: []},
      metaTotalPages: 1,
    )..failDstatsWithWall = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final books = container.read(downloadedBooksProvider).valueOrNull!;
    expect(books.length, 1);
    expect(books.first.id, 23787383);
    expect(books.first.title, '书甲');
    expect(
      books.first.downloadedAt,
      DateTime(2026, 11, 11, 21, 2),
    );
    expect(fallbackCalls, 3);
  });

  test('可见 solver 也拿不到真页：仍抛原始墙错误', () async {
    WebviewChallengeSolver.overrideIsSupported = true;
    WebviewChallengeSolver.overrideIsMobile = true;
    WebviewChallengeSolver.guiEnabled = false;
    addTearDown(() {
      WebviewChallengeSolver.overrideIsSupported = null;
      WebviewChallengeSolver.overrideIsMobile = null;
      WebviewChallengeSolver.guiEnabled = true;
      WebviewChallengeSolver.visibleSolverFallback = null;
    });

    // 两次都只拿到空 503 页：无头一次，可见升级一次。
    var fallbackCalls = 0;
    WebviewChallengeSolver.visibleSolverFallback = (url) async {
      fallbackCalls++;
      return _bare503Html;
    };

    final api = _FakeZLibraryApi(
      metaPages: {1: []},
      metaTotalPages: 1,
    )..failDstatsWithWall = true;
    final container = _container(api);
    addTearDown(container.dispose);

    container.read(downloadedBooksProvider);
    await _settle();

    final state = container.read(downloadedBooksProvider);
    expect(state, isA<AsyncError>());
    expect(
      (state as AsyncError).error.toString(),
      contains('browser check page'),
    );
    expect(fallbackCalls, 2);
  });
}
