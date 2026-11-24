import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// The last-resort download channel: `/dl/{token}`, the address the
// site puts on an HTML card and a detail page, used only after the
// eapi file endpoint has actually refused the book's hash.
//
// Two production shapes these tests pin down, both measured
// 2026-11-24 on zh.z-library.sk and both previously unreachable:
//  * the refusal is `HTTP 400` + a JSON body whose error is LOCALISED
//    (`无效哈希`, not `Invalid hash`). A probe with the default
//    `validateStatus` never read that body, and a matcher that only
//    knew the English wording would still have skipped every retry
//    branch. Both are reproduced here, not simulated away.
//  * the search endpoint `resolveEapiHash` depended on is dead
//    (`POST /eapi/book/search` → `400 Access denied`), so a book that
//    arrived through HTML has no hash to resolve and `/dl/…` is the
//    only address it has.
//
// What must NOT change: a quota/auth/server failure stays an error
// (the app re-checks the quota on throw — silently switching channels
// would hide it), a link on another host is refused (the session
// cookie must not follow a book to a third party), and a resolvable
// hash still wins over the HTML link.

const _bookId = '26610712';
const _shortHash = 'Ej8q7Dmrv9';
const _eapiHash = '217fd6';
const _dlToken = '/dl/ABVGVr08wz';
const _fileBytes = 'fake-epub-bytes';

/// 浏览器在 `/dl/` 那一跳被交予的地址所指向的文件内容（第 9 轮）。和
/// [_fileBytes] 分开写，是为了让断言能说出**哪一发**落的盘。
const _browserFileBytes = 'browser-handed-file';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter();

  /// Status of `/eapi/book/{id}/{hash}/file`.
  int fileStatus = 400;

  /// The `error` the file endpoint answers with.
  String fileError = '无效哈希';

  /// Body for `POST /eapi/book/search`; null means Access denied.
  Map<String, dynamic>? searchPayload;

  /// 头几次 `/dl/` 请求回浏览器校验页（503 + HTML）。1 = 撞一次墙、
  /// 求解之后第二次拿到文件（2026-11-24 真机报告的形状）；很大的值 =
  /// 每次都撞墙，用来证明求解不会循环。
  int dlWallAnswers = 0;

  /// `/dl/` 回一张 HTML 错误页而不是校验页（`<html>` + 没标记）：
  /// 这种答案绝不许触发求解。
  bool dlErrorPage = false;

  /// eapi 解析出来的那张 CDN 直链回 503 校验页：求解会把会话装进
  /// **那个 host** 的 WebView cookie jar，所以第三方主机一律不许解。
  bool cdnWalls = false;

  /// 书页候选的答复（卡片什么都没带时下载会自己去造 `/book/{id}/{hash}/`）。
  /// null = 那个形状 404，`_FakeAdapter` 走默认分支。
  String? bookPageHtml;

  /// 只把**第一发**书页候选按这个状态答（换形状那条：hash 形状不存在、
  /// 只有 `/book/{id}/` 跳得到书页）。
  int? firstPageStatus;

  /// 书页自己站在墙后：第一发回 503 校验页，求解（`wallCookieRefresh`）
  /// 之后回 [bookPageHtml]。
  bool pageWalls = false;

  /// 解过之后仍然回校验页：墙 cookie 一枚都没搬进 Dio 时的真实形状
  /// （求解成功的 WebView 和重发失败的 Dio 之间差的就是这个）。
  bool pageAlwaysWalls = false;

  /// 第 9 轮：求解钩子交回来的「浏览器在 `/dl/` 那一跳被交予的文件地址」。
  /// null = 这一发根本不存在（钩子没记、或记的被拒收）。
  String? capturedFileUrl;

  /// 落在 [capturedFileUrl] 那一发上送出的 `Cookie` 头。跨主机的直链必须
  /// 整个摘掉 Cookie（那上面的凭证是签名参数，不是会话），本站的必须带——
  /// 这是"浏览器指的路有没有把会话漏给第三方"唯一的观测点。
  final List<String?> fileCookies = [];

  int _pageAnswers = 0;

  final List<String> requestedPaths = [];

  /// 每次 `/dl/` 请求送出的 `Cookie` 头（重试用的是重新取的那份头，
  /// 沿用旧副本就看不见回灌进来的墙 cookie——这条只能在这里钉住）。
  final List<String?> dlCookies = [];

  int _dlHits = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requestedPaths.add(path);
    if (path.endsWith('/file')) {
      if (path == '/eapi/book/$_bookId/$_eapiHash/file') {
        return _json({
          'success': 1,
          'downloadLink': 'https://cdn.example.com/resolved.epub',
        });
      }
      // The refusal carries the site's localised text in a JSON body
      // behind a 400 — exactly the production shape.
      return _json({'success': 0, 'error': fileError}, statusCode: fileStatus);
    }
    if (path == '/eapi/book/search') {
      return _json(
        searchPayload ?? {'success': 0, 'error': 'Access denied'},
        statusCode: searchPayload == null ? 400 : 200,
      );
    }
    if (path.startsWith('/book/')) {
      final answer = _pageAnswers++;
      if (pageWalls && (pageAlwaysWalls || answer == 0)) {
        return ResponseBody.fromString(
          '<html><head><title>Checking your browser</title>'
          '</head><body>ddos-guard</body></html>',
          503,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      }
      final miss = answer == 0 ? firstPageStatus : null;
      if (miss != null) {
        return ResponseBody.fromString(
          '<html><body>Not found</body></html>',
          miss,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      }
      final html = bookPageHtml;
      if (html == null) return ResponseBody.fromString('', 404);
      return ResponseBody.fromString(
        html,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final captured = capturedFileUrl;
    if (captured != null && path == Uri.parse(captured).path) {
      fileCookies.add(options.headers['Cookie']?.toString());
      return ResponseBody.fromBytes(
        utf8.encode(_browserFileBytes),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/epub+zip'],
          Headers.contentLengthHeader: [
            utf8.encode(_browserFileBytes).length.toString(),
          ],
        },
      );
    }
    if (path == _dlToken) {
      _dlHits++;
      dlCookies.add(options.headers['Cookie']?.toString());
      if (dlErrorPage) {
        return ResponseBody.fromString(
          '<html><body>Book not found</body></html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      }
      if (_dlHits <= dlWallAnswers) {
        return ResponseBody.fromString(
          '<html><head><title>Checking your browser</title>'
          '</head><body>ddos-guard</body></html>',
          503,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      }
      return ResponseBody.fromBytes(
        utf8.encode(_fileBytes),
        200,
        headers: {
          Headers.contentTypeHeader: [
            'application/epub+zip',
          ],
          Headers.contentLengthHeader: [utf8.encode(_fileBytes).length.toString()],
        },
      );
    }
    if (path == '/resolved.epub') {
      if (cdnWalls) {
        return ResponseBody.fromString(
          '<html><head><title>Checking your browser</title></head></html>',
          503,
          headers: {Headers.contentTypeHeader: ['text/html; charset=utf-8']},
        );
      }
      return ResponseBody.fromBytes(
        utf8.encode('resolved-bytes'),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/epub+zip'],
          Headers.contentLengthHeader: [
            utf8.encode('resolved-bytes').length.toString(),
          ],
        },
      );
    }
    return ResponseBody.fromString('', 404);
  }

  ResponseBody _json(Map<String, dynamic> payload, {int statusCode = 200}) =>
      ResponseBody.fromString(
        jsonEncode(payload),
        statusCode,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tempDir;
  late _FakeAdapter adapter;
  late ZLibraryApi api;
  late String savePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zlibx_dl_html');
    savePath = '${tempDir.path}/book.epub';
    adapter = _FakeAdapter();
    api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
    // No persisted short→real mapping in these tests.
    ZLibraryApiBase.resolveCacheLookup = null;
    ZLibraryApiBase.resolveCacheWrite = null;
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String ownDlLink() => 'https://${api.domain}$_dlToken';

  /// 跑一次下载，把那句失败文案拿回来——书页那条腿的产出就是这句话，
  /// 断言它比断言"抛了个 StateError"有意义得多。
  Future<String> captureStateError() async {
    try {
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
    } on StateError catch (e) {
      return e.message;
    }
    throw StateError('expected the download to fail, but it succeeded');
  }

  test('a rejected short hash falls back to the page /dl/ link', () async {
    await api.downloadBook(
      _bookId,
      _shortHash,
      savePath,
      title: '三体',
      htmlDownloadLink: ownDlLink(),
    );
    expect(File(savePath).readAsStringSync(), _fileBytes);
    expect(adapter.requestedPaths, contains(_dlToken));
  });

  test('the English wording falls back the same way', () async {
    adapter.fileError = 'Invalid hash';
    await api.downloadBook(
      _bookId,
      _shortHash,
      savePath,
      title: '三体',
      htmlDownloadLink: ownDlLink(),
    );
    expect(File(savePath).readAsStringSync(), _fileBytes);
  });

  test('with no /dl/ link the rejection still surfaces as an error',
      () async {
    await expectLater(
      api.downloadBook(_bookId, _shortHash, savePath, title: '三体'),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a quota refusal never switches channels', () async {
    // The app re-reads the quota when a download throws; answering a
    // quota error with a silent /dl/ retry would report a success the
    // account does not have.
    adapter.fileError = 'You have reached your daily download limit';
    await expectLater(
      api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        htmlDownloadLink: ownDlLink(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a non-https /dl/ link is refused', () async {
    await expectLater(
      api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        htmlDownloadLink: 'http://${api.domain}$_dlToken',
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a /dl/ link on a foreign host is refused', () async {
    await expectLater(
      api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        htmlDownloadLink: 'https://evil.example$_dlToken',
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a relative /dl/ link is refused (no scheme to check)', () async {
    await expectLater(
      api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        htmlDownloadLink: _dlToken,
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a resolvable eapi hash still wins over the HTML link', () async {
    // eapi primary, HTML fallback — a search hit must be used, and the
    // file endpoint's own link followed, even when a /dl/ token is
    // available.
    adapter.searchPayload = {
      'success': 1,
      'books': [
        {'id': int.parse(_bookId), 'hash': _eapiHash, 'title': '三体'},
      ],
    };
    await api.downloadBook(
      _bookId,
      _shortHash,
      savePath,
      title: '三体',
      htmlDownloadLink: ownDlLink(),
    );
    expect(File(savePath).readAsStringSync(), 'resolved-bytes');
    expect(adapter.requestedPaths, isNot(contains(_dlToken)));
  });

  test('a 10-character search hit is never treated as a resolution',
      () async {
    // `resolveEapiHash` only accepts the 6-character eapi shape. A
    // search hit carrying some other length (a webpage short hash, as
    // an HTML-sourced search result would) is not a resolution: it
    // would be written into the mapping and replayed forever as the
    // "real" hash, pinning the book to a call eapi always rejects.
    // With the guard, the doomed second file call never happens, no
    // mapping is written, and the /dl/ token downloads the book.
    const decoy = 'Zq9Tm2Kp4x';
    final written = <List<String>>[];
    ZLibraryApiBase.resolveCacheWrite = (bookId, hash, resolved) {
      written.add([bookId, hash, resolved]);
    };
    adapter.searchPayload = {
      'success': 1,
      'books': [
        {'id': int.parse(_bookId), 'hash': decoy, 'title': '三体'},
      ],
    };
    await api.downloadBook(
      _bookId,
      _shortHash,
      savePath,
      title: '三体',
      htmlDownloadLink: ownDlLink(),
    );
    expect(File(savePath).readAsStringSync(), _fileBytes);
    expect(
      adapter.requestedPaths.where((p) => p.endsWith('/file')).length,
      1,
      reason: 'a non-eapi hit must not trigger a second file call',
    );
    expect(written, isEmpty);
  });

  // 2026-11-24 真机第二份探针报告钉下来的形状：`/dl/{token}` 本身就站在
  // 浏览器校验后面——三种请求头策略都在**同一跳**拿到 `HTTP 503 +
  // text/html`，一次重定向都没发生。带不带 cookie / Referer 都不参与
  // 结果，能改变答复的只有先去过一次墙（App 注入的 `wallCookieRefresh`，
  // 插件开不了 WebView），再把同一发请求重发。
  group('the walled /dl/ route', () {
    Future<void> download() => api.downloadBook(
      _bookId,
      _shortHash,
      savePath,
      title: '三体',
      htmlDownloadLink: ownDlLink(),
    );

    int dlRequests() =>
        adapter.requestedPaths.where((p) => p == _dlToken).length;

    test('a wall is solved once and the retry writes the book', () async {
      final solved = <String>[];
      api.wallCookieRefresh = (url) async {
        solved.add(url);
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      adapter.dlWallAnswers = 1;
      await download();
      expect(File(savePath).readAsStringSync(), _fileBytes);
      // 求解的就是那个被墙挡住的地址，原样（token 在内）——它是目标，
      // 不是证据文本，所以这里能拿到、报告文本里必须掩码。
      expect(solved, [ownDlLink()]);
      expect(dlRequests(), 2);
    });

    test('the retry re-reads the headers, so the clearance rides along',
        () async {
      // 求解后 `setWallCookies` 把墙 cookie 装进实例；重试若沿用求解前
      // 那份 header 副本，第二次请求照样没 cookie——墙白过，下一本还是
      // 同一个 503。这条只钉这一件事。
      api.wallCookieRefresh = (url) async {
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      adapter.dlWallAnswers = 1;
      await download();
      expect(adapter.dlCookies.first, isNot(contains('__diamwall')));
      expect(adapter.dlCookies.last, contains('__diamwall'));
    });

    test('a wall that stays a wall is not solved twice', () async {
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      adapter.dlWallAnswers = 99;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.isWall,
            'isWall',
            isTrue,
          ),
        ),
      );
      expect(solves, 1, reason: 'one solve per download, never a loop');
      expect(dlRequests(), 2);
    });

    // 真机第 7 份报告（第 9 轮的来由）：解过墙、重发 `/dl/{token}`，答
    // 回来的仍是 `HTTP 503 + text/html`。过墙的凭证跟着那个 WebView 走，
    // Dio 这一侧重发并不认——而浏览器**同一发** `/dl/` 是能一路走到文件
    // 的。所以求解那一发除了回灌 cookie，还要把浏览器被交予的地址带回来，
    // 下载改从那个地址落盘。下面四条钉的就是这条取路。
    test('a file URL captured by the solve replaces the walled /dl/ hop',
        () async {
      const fileUrl = 'https://dl-cdn.example.com/f/9f2c/book.epub?x=1';
      api.wallCookieRefresh = (url) async {
        api.recordDlFileCapture(url, fileUrl: fileUrl);
        return true;
      };
      adapter.dlWallAnswers = 99;
      adapter.capturedFileUrl = fileUrl;
      await download();
      expect(File(savePath).readAsStringSync(), _browserFileBytes);
      // `/dl/` 只被撞了一次：省下的那一发重发就是这条取路的意义。
      expect(dlRequests(), 1);
      // 第三方直链上不许带会话/墙 cookie。
      expect(adapter.fileCookies, [null]);
    });

    test('a capture on the mirror host keeps the clearance cookies', () async {
      const fileUrl = 'https://bookroom.lifestyle/file/own-host.epub';
      api.wallCookieRefresh = (url) async {
        api.setWallCookies({'__diamwall': 'clearance-value'});
        api.recordDlFileCapture(url, fileUrl: fileUrl);
        return true;
      };
      adapter.dlWallAnswers = 99;
      adapter.capturedFileUrl = fileUrl;
      await download();
      expect(File(savePath).readAsStringSync(), _browserFileBytes);
      expect(adapter.fileCookies.single, contains('__diamwall'));
    });

    test('a capture serves one download only', () async {
      const fileUrl = 'https://dl-cdn.example.com/f/first.epub';
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        if (solves == 1) {
          api.recordDlFileCapture(url, fileUrl: fileUrl);
        }
        return true;
      };
      adapter.dlWallAnswers = 99;
      adapter.capturedFileUrl = fileUrl;
      await download();
      expect(File(savePath).readAsStringSync(), _browserFileBytes);
      // 第二本：钩子不再记地址。上一本的直链绝不能顶给它——那会把一本书
      // 写成另一本，而用户只在打开时才发现。
      await File(savePath).delete();
      await expectLater(download(), throwsA(isA<DownloadHtmlException>()));
      expect(solves, 2);
      expect(adapter.fileCookies.length, 1);
    });

    test('a capture that is not https is refused and the failure says so',
        () async {
      api.wallCookieRefresh = (url) async {
        api.recordDlFileCapture(
          url,
          fileUrl: 'http://dl-cdn.example.com/f/insecure.epub',
        );
        return true;
      };
      adapter.dlWallAnswers = 99;
      adapter.capturedFileUrl = '/f/insecure.epub';
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('download is behind the browser check'),
                contains('已过墙')),
          ),
        ),
      );
      // 被拒收 → 退回老路：重发一次 `/dl/`，仍然撞墙。
      expect(dlRequests(), 2);
      expect(adapter.fileCookies, isEmpty);
    });

    test('the failure line separates "no solve" from "solved, still walled"',
        () async {
      // 「解过墙、这一跳还是 503」和「这台设备的求解说没过」在截图里以前
      // 是同一句话，而它们的修法相反：前者要查抓取那条腿，后者压根没开窗。
      api.wallCookieRefresh = (url) async => true;
      adapter.dlWallAnswers = 99;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('download is behind the browser check'),
                contains('已过墙')),
          ),
        ),
      );

      if (File(savePath).existsSync()) await File(savePath).delete();
      api.wallCookieRefresh = (url) async => false;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.message,
            'message',
            contains('过墙未成'),
          ),
        ),
      );
    });

    test('without a solver the wall surfaces as the wall error', () async {
      // 纯 Dio 环境（单测 / CI）：不猜、不重试，文案里带上掩码
      // 地址，截图就能定位。
      adapter.dlWallAnswers = 99;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>()
              .having((e) => e.isWall, 'isWall', isTrue)
              .having((e) => e.message, 'message', contains('/dl/ABVG')),
        ),
      );
      expect(dlRequests(), 1);
      expect(File(savePath).existsSync(), isFalse);
    });

    test('a solve that says no buys no retry', () async {
      api.wallCookieRefresh = (url) async => false;
      adapter.dlWallAnswers = 99;
      await expectLater(download(), throwsA(isA<DownloadHtmlException>()));
      expect(dlRequests(), 1);
    });

    test('an HTML error page is not a wall and costs no solve', () async {
      // 一张 `Book not found` 也是 text/html。过墙对它一点用都没有，
      // 却要用户等一次 WebView 求解——所以 isWall 必须按答复内容分，
      // 而不是按"拿到的是不是 HTML"分。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      adapter.dlErrorPage = true;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.isWall,
            'isWall',
            isFalse,
          ),
        ),
      );
      expect(solves, 0);
      expect(dlRequests(), 1);
    });

    test('a wall on a foreign host buys no solve', () async {
      // eapi 解析出来的直链在 CDN 上。App 那一腿求解前要把
      // remix_userid / remix_userkey 装进 WebView 的 cookie jar，而 jar
      // 是按 URL 的 host 写的——照着一条第三方地址去解，等于把登录会话
      // 送出去。本站校验必须在这里拦住，错误照旧抛。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      adapter.searchPayload = {
        'success': 1,
        'books': [
          {'id': int.parse(_bookId), 'hash': _eapiHash, 'title': '三体'},
        ],
      };
      adapter.cdnWalls = true;
      await expectLater(
        download(),
        throwsA(
          isA<DownloadHtmlException>().having(
            (e) => e.isWall,
            'isWall',
            isTrue,
          ),
        ),
      );
      expect(solves, 0, reason: 'a foreign host is never a wall to solve');
    });
  });

  // 2026-11-24 真机第三份报告：任务里 `downloadPath` 和 `href` **都**是空
  // 的（相似书/推荐卡片只带 id + 10 位 hash）。上一条通道要的是"HTML 里
  // 出现过的地址"，两样都没有就整条腿短路——探针因此一发请求都没发，那份
  // 报告读起来像"这本书没有 /dl/"，其实是谁都没去看。书页地址是站自己按
  // `/book/{hash}/{标题}.html` 编的（2026-11-24 真页面 241 个 `/book/`
  // 链接全是这一形状），hash + 标题在手就能现造。
  group('the page-built /dl/ address', () {
    int pageFetches() => adapter.requestedPaths
        .where((p) => p.startsWith('/book/'))
        .length;

    List<String> pagePaths() => adapter.requestedPaths
        .where((p) => p.startsWith('/book/'))
        .toList();

    test('a task with no link at all gets its token off the book page',
        () async {
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(File(savePath).readAsStringSync(), _fileBytes);
      expect(pagePaths(), [_dlPagePath]);
      expect(adapter.requestedPaths, contains(_dlToken));
    });

    test('the candidates run in the order the site really serves', () {
      // 顺序就是证据：`/book/{hash}/{标题}.html` 是页面上唯一出现过的形状，
      // 旧的 `/book/{id}/{hash}/` 退到末位（真机第 8 轮报告里读回首页的
      // 正是它）。形状一改，下载就又瞎了——这条测试钉住它。
      final host = 'https://${api.domain}';
      expect(
        api.bookPageCandidates(_bookId, _shortHash, title: '三体'),
        [
          '$host$_dlPagePath',
          '$host/book/$_shortHash/',
          '$host$_legacyPagePath',
          '$host/book/$_bookId/',
        ],
      );
      // 卡片自己的 href 永远排第一（站写的 slug 不会错）。
      expect(
        api.bookPageCandidates(
          _bookId,
          _shortHash,
          title: '三体',
          href: '/book/$_shortHash/some-slug.html',
        ).first,
        '$host/book/$_shortHash/some-slug.html',
      );
    });

    test('the synthesized slug follows the site\'s own spelling rule', () {
      // 取自那份真页面里 58 组 `(z-cover title, href slug)` 对照的四种代
      // 表形状：全角冒号消失、空白折成连字符、字母小写、纯标点没有 slug。
      final host = 'https://${api.domain}';
      String first(String title) =>
          api.bookPageCandidates(_bookId, _shortHash, title: title).first;
      String slug(String text) => Uri.encodeComponent(text);
      expect(
        first('给仰望者的星空史：天文如何塑造人类历史'),
        '$host/book/$_shortHash/${slug('给仰望者的星空史天文如何塑造人类历史')}.html',
      );
      expect(first('星辰的故事 - 星座与人类'), contains(slug('星辰的故事-星座与人类')));
      expect(first('BBC 及每日邮报'), contains(slug('bbc-及每日邮报')));
      // 一个标点都没有可用字符：跳过这一发，不拿 `/book/{hash}/.html` 去撞。
      expect(first('！！！'), '$host/book/$_shortHash/');
    });

    test('a page shape that 404s gets the id-only shape', () async {
      // `/book/{id}/{hash}/` 在这个镜像上不存在（hash 是 eapi 那 6 位、
      // 或站点改了结构）不等于"这本书没有下载地址"。
      adapter.firstPageStatus = 404;
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(pageFetches(), 2);
      expect(adapter.requestedPaths.last, _dlToken);
    });

    test('a walled book page is solved once, then the token downloads',
        () async {
      final solved = <String>[];
      api.wallCookieRefresh = (url) async {
        solved.add(url);
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      adapter.pageWalls = true;
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(File(savePath).readAsStringSync(), _fileBytes);
      // 求解的就是那页书页本身（含 id + hash），不是猜出来的 /dl/。
      expect(solved, ['https://${api.domain}$_dlPagePath']);
      expect(pageFetches(), 2);
    });

    test('a solved page and a walled /dl/ cost two solves, not three',
        () async {
      // 一本书的封顶：书页一发 + 下载一跳各一次。再多就是拿同一道墙
      // 反复开 WebView，而下载本身已经失败了两次。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      adapter.pageWalls = true;
      adapter.bookPageHtml = _pageWithDlButton;
      adapter.dlWallAnswers = 1;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(solves, 2);
      expect(File(savePath).readAsStringSync(), _fileBytes);
    });

    test('a page that answers no button keeps the hash error', () async {
      // 这一发是"额外一试"：它自己没结果不能顶掉原本那句无效哈希，否则
      // 用户看到的就不是下载失败的原因了。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      adapter.bookPageHtml = _pageWithoutButton;
      await expectLater(
        api.downloadBook(_bookId, _shortHash, savePath, title: '三体'),
        throwsA(isA<StateError>()),
      );
      expect(pageFetches(), 1, reason: 'a read page is a definite answer');
      expect(solves, 0, reason: 'a page that answered is not a wall');
      expect(adapter.requestedPaths, isNot(contains(_dlToken)));
    });

    test('a hidden template copy of the button is not an address', () async {
      // 页面里那枚 `<template>` 副本是站点留着复用的，用户点不到它——
      // 照它下载等于拿一个可能过期的 token 去撞墙。可见按钮才算数。
      adapter.bookPageHtml = _pageWithHiddenButtonOnly;
      await expectLater(
        api.downloadBook(_bookId, _shortHash, savePath, title: '三体'),
        throwsA(isA<StateError>()),
      );
      expect(pageFetches(), 1);
      expect(adapter.requestedPaths, isNot(contains(_dlToken)));
    });

    test('a quota refusal never pays for a page fetch', () async {
      // 早停之外更要紧的一条：额度错误必须原样抛出去（App 靠它重查额度），
      // 不能变成"再去书页看看有没有别的地址"。
      adapter.fileError = 'You have reached your daily download limit';
      adapter.bookPageHtml = _pageWithDlButton;
      await expectLater(
        api.downloadBook(_bookId, _shortHash, savePath, title: '三体'),
        throwsA(isA<StateError>()),
      );
      expect(pageFetches(), 0);
      expect(adapter.requestedPaths, isNot(contains(_dlToken)));
    });

    test('a card that carries the link never pays for a page fetch',
        () async {
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        htmlDownloadLink: ownDlLink(),
      );
      expect(pageFetches(), 0);
    });

    test('the resolvable-hash path never touches the page', () async {
      adapter.searchPayload = {
        'success': 1,
        'books': [
          {'id': int.parse(_bookId), 'hash': _eapiHash, 'title': '三体'},
        ],
      };
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(File(savePath).readAsStringSync(), 'resolved-bytes');
      expect(pageFetches(), 0);
    });
  });

  // 2026-11-24 真机第四份报告（毛选那本）：书页那条腿跑完了，屏幕上仍然
  // 只有一句 `Bad state: Invalid hash`。那一腿有三种彼此完全不同的空手
  // 方式——解墙没成、解成了但墙那枚 cookie 的**名字**不在 App 白名单里
  // （于是 0 枚回灌，重发必然还是墙）、页面读到了可里面没有可见按钮——
  // 三种都要不同的修法，却挤在同一句话里。
  //
  // 新的主路是 `wallHtmlFetcher`：App 用真浏览器把那页 HTML 读回来（书单
  // 和详情页在真机上走的就是这条通道，它已经被证明能过墙），插件只从
  // HTML 里取按钮。它不需要墙 cookie 进 Dio，所以白名单叫什么名字都不
  // 再影响结果。
  group('the browser-read book page', () {
    int pageFetches() =>
        adapter.requestedPaths.where((p) => p.startsWith('/book/')).length;
    test('the HTML carries the button, so nothing has to be bridged',
        () async {
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      final read = <String>[];
      api.wallHtmlFetcher = (url) async {
        read.add(url);
        return _pageWithDlButton;
      };
      adapter.pageWalls = true;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(File(savePath).readAsStringSync(), _fileBytes);
      // 读的就是那一页自己（含 id + hash），不是猜出来的 /dl/。
      expect(read, ['https://${api.domain}$_dlPagePath']);
      expect(solves, 0, reason: 'the button is already in that HTML');
      expect(pageFetches(), 1, reason: 'no Dio refetch after the read');
    });

    test('a read page with no visible button is a definite answer', () async {
      // 浏览器把页面读回来了却没有按钮 → 这本书就是没有站内下载地址。
      // 绝不再拿 Dio 重发一遍（那只会再撞一次墙，然后报成"墙"）。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      api.wallHtmlFetcher = (url) async => _pageWithoutButton;
      adapter.pageWalls = true;
      final err = await captureStateError();
      expect(solves, 0);
      expect(pageFetches(), 1);
      expect(adapter.requestedPaths, isNot(contains(_dlToken)));
      // 这句话得自己说清"页面里确实没有按钮"（`no-link`），而不是让人
      // 猜是没读回来、也不是报成墙——两种原因的修法相反。
      expect(err, contains('no-link'));
      expect(err, isNot(contains('wall')));
    });

    test('a page that is really the homepage cannot donate another book '
        'token, and is not a verdict either', () async {
      // 浏览器读回来的可能是首页：里面的 `/dl/` 按钮属于别的书，既不能
      // 当成地址（那是下错一本书），也不能当成"这本书没有下载地址"的定论
      // ——第 8 轮真机报告正是这一页（页题 `Z-Library – the w…`），而旧
      // 早停在第一发就收工，`/book/{id}/` 那发根本没跑过。
      var solves = 0;
      final read = <String>[];
      api.wallCookieRefresh = (url) async {
        solves++;
        return true;
      };
      api.wallHtmlFetcher = (url) async {
        read.add(url);
        return _pageLooksLikeHomepage;
      };
      // 真机上这个镜像的 `/book/…` 对 Dio 永远回校验页（第 2 份报告三发
      // 全是 503），HTML 只能从浏览器那条腿拿——所以第二发也得走墙。
      adapter.pageWalls = true;
      adapter.pageAlwaysWalls = true;
      final err = await captureStateError();
      expect(read.length, 2, reason: '两个形状各读一页，额度用完不再开窗');
      expect(solves, 1, reason: '第三发不再有 WebView，只剩 Dio 那一发求解');
      expect(err, contains('no-link'));
      expect(adapter.requestedPaths, isNot(contains('/dl/SOMEOTHER1')));
    });

    test('the card\'s own page address rescues a title whose slug moved',
        () async {
      // 真页面证明：卡片 href 是站写的，slug 一定对得上；用标题现造的那一发
      // 只有在书名被编辑过才会跳不到页（58 组对照里 1 组如此）。旧代码从
      // 不用卡片 href，第一发又是站里不存在的 `/book/{id}/{hash}/`，所以
      // 每一本短 hash 的书都只能读回首页——第 8 轮真机报告就是这么来的。
      final stale = 'https://${api.domain}/book/$_shortHash/%E6%97%A7%E4%B9%A6%E5%90%8D.html';
      final read = <String>[];
      api.wallHtmlFetcher = (url) async {
        read.add(url);
        return url == stale ? _pageLooksLikeHomepage : _pageWithDlButton;
      };
      adapter.pageWalls = true;
      adapter.pageAlwaysWalls = true;
      await api.downloadBook(
        _bookId,
        _shortHash,
        savePath,
        title: '三体',
        bookPageHref: stale,
      );
      expect(File(savePath).readAsStringSync(), _fileBytes);
      // 先读卡片给的那一发，首页了才轮到现造的 slug。
      expect(read.first, stale);
      expect(read.length, 2);
      expect(adapter.requestedPaths, contains(_dlToken));
    });

    test('without the fetcher the solve-and-refetch path still downloads',
        () async {
      // 纯 Dio 环境（单测、CI）和没接这条腿的版本：旧路径必须原样可用。
      var solves = 0;
      api.wallCookieRefresh = (url) async {
        solves++;
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      api.wallHtmlFetcher = (url) async => null;
      adapter.pageWalls = true;
      adapter.bookPageHtml = _pageWithDlButton;
      await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      expect(solves, 1);
      expect(pageFetches(), 2);
      expect(File(savePath).readAsStringSync(), _fileBytes);
    });

    test('the failure names the page arm, not just the hash', () async {
      // 那句 `Invalid hash` 单独存在时什么都没说：卡在哪一跳、App 到底
      // 解没解墙，两种原因的修法相反。文案要分出这两样，同时一个凭证值
      // 都不许出现。
      api.wallHtmlFetcher = (url) async => null;
      api.wallCookieRefresh = (url) async {
        api.setWallCookies({'__diamwall': 'clearance-value'});
        return true;
      };
      adapter.pageWalls = true;
      adapter.pageAlwaysWalls = true;
      late Object failure;
      try {
        await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      } catch (e) {
        failure = e;
      }
      final message = (failure as StateError).message.toString();
      expect(message, contains('无效哈希'));
      expect(message, contains('书页'));
      expect(message, contains('wall'));
      // 名字进得来，值进不来：`clearance-value` 是会话级的墙凭证。
      expect(message, isNot(contains('clearance-value')));
      expect(message, isNot(contains(_shortHash)));
      expect(File(savePath).existsSync(), isFalse);
    });

    test('a page read by the browser reports no-link, not wall', () async {
      api.wallHtmlFetcher = (url) async => _pageWithoutButton;
      adapter.pageWalls = true;
      adapter.pageAlwaysWalls = true;
      late Object failure;
      try {
        await api.downloadBook(_bookId, _shortHash, savePath, title: '三体');
      } catch (e) {
        failure = e;
      }
      final message = (failure as StateError).message.toString();
      expect(message, contains('no-link'));
      expect(message, isNot(contains('wall')), reason: 'the read settled it');
    });
  });
}

/// 站里真正在用的书页地址：`/book/{hash}/{标题}.html`。2026-11-24 那份
/// 5.8 MB 真页面里 241 个 `/book/` 链接全是这一形状（连面包屑 `@id` 都是），
/// `/book/{id}/{hash}/` 一次都没出现——那条路由不存在，读回来必然是首页。
const _dlPagePath = '/book/$_shortHash/%E4%B8%89%E4%BD%93.html';

/// 旧代码的第一候选（已退到末位）：形状在站里不存在。
const _legacyPagePath = '/book/$_bookId/$_shortHash/';

const _pageWithDlButton = '''
<html><head>
<title>三体 | 刘慈欣 | download on Z-Library</title>
<script type="application/ld+json">
{"@type":"Book","name":"三体","author":[{"name":"刘慈欣"}]}
</script>
</head><body>
<div data-book_id="$_bookId"></div>
<h1 class="book-title">三体</h1>
<i class="authors">刘慈欣</i>
<div id="bookDescriptionBox"><p>正文。</p></div>
<a class="btn btn-primary dlButton reader-link" href="https://reader.z-library.sk/read/80eb6002d082/book/Ej8q7Dmrv9/%E4%B8%89%E4%BD%93.html?extension=epub&download_location=https%3A%2F%2Fzh.z-library.sk$_dlToken">在线阅读</a>
<a class="btn btn-default dlButton addDownloadedBook" href="https://zh.z-library.sk$_dlToken" data-book_id="$_bookId" data-isbn="9787229042066" rel="nofollow">epub, 2.48 MB</a>
</body></html>
''';

const _pageWithoutButton = '''
<html><head>
<title>三体 | 刘慈欣 | download on Z-Library</title>
<script type="application/ld+json">
{"@type":"Book","name":"三体","author":[{"name":"刘慈欣"}]}
</script>
</head><body>
<div data-book_id="$_bookId"></div>
<h1 class="book-title">三体</h1>
<div id="bookDescriptionBox"><p>正文。</p></div>
</body></html>
''';

/// 匿名访问 `/book/{id}/{hash}/` 被弹回首页时读回来的那一页：书 id 不在
/// 页面里，也没有任何 `/dl/` 锚点。它和上面那张（确实是书页、只是没有
/// 按钮）是两种相反的病因，报告里必须分得开。
const _pageLooksLikeHomepage = '''
<html><head><title>Z-Library: Book library</title></head>
<body>
<h1>Search books</h1>
<a href="/search">Search</a>
<a class="dlButton addDownloadedBook" data-book_id="99999999" href="/dl/SOMEOTHER1">下载</a>
</body></html>
''';

const _pageWithHiddenButtonOnly = '''
<html><head>
<script type="application/ld+json">
{"@type":"Book","name":"三体","author":[{"name":"刘慈欣"}]}
</script>
</head><body>
<div data-book_id="$_bookId"></div>
<h1 class="book-title">三体</h1>
<div id="bookDescriptionBox"><p>正文。</p></div>
<template><a class="dlButton addDownloadedBook" href="$_dlToken" hidden></a></template>
</body></html>
''';
