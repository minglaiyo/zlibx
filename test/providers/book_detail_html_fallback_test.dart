import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/book_details_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';

// The detail screen's fallback body: when eapi cannot address a book
// at all, the screen reads the book off its own page instead of
// showing an error.
//
// The trigger is the hash SHAPE, not the error text, and it is a
// site fact measured 2026-11-24: eapi wants a 6-character hash, an
// HTML-sourced book only ever carries the site's 10-character short
// one, and nothing on the webpage exposes the eapi form (`/eapi/book/
// 26610712/Ej8q7Dmrv9` → `400 无效哈希`; a same-length-but-wrong hash
// is refused identically, so the value cannot be derived). The route
// that used to translate the two — `resolveEapiHash` over
// `/eapi/book/search` — is dead, so this fallback is the only channel
// left for that population, and the tests below are what keeps it
// narrow:
//  * a 6-character hash that still failed means the book is gone or
//    the session broke — the error must reach the user, not be papered
//    over with whatever page the solver landed on;
//  * no href → nothing to fetch;
//  * a fallback that itself fails (or throws) keeps the original
//    error text.
//
// Only the Dio-level channel is exercised here: the WebView solve
// behind a real DiamWall needs a device.

Book _eapiBook() => Book(
  id: 26610712,
  title: '三体',
  description: 'eapi 正文',
  hash: '217fd6',
);

Book _htmlBook() => Book(
  id: 26610712,
  title: '三体',
  author: '刘慈欣',
  description: '详情页正文',
  hash: 'Ej8q7Dmrv9',
  href: '/book/Ej8q7Dmrv9/三体.html',
  downloadPath: 'https://zh.z-library.sk/dl/ABVGVr08wz',
);

class _FakeApi implements ZLibraryApi {
  _FakeApi({
    required this.detail,
    this.htmlBook,
    this.htmlError,
    this.htmlThrows = false,
  });

  /// What the eapi detail call answers.
  final ApiResponse<Book> detail;

  /// What the detail-page channel answers (null: it is not set up).
  final Book? htmlBook;

  final String? htmlError;

  /// The HTML channel throws instead of returning (a fake built
  /// without the method behaves the same way).
  final bool htmlThrows;

  int detailCalls = 0;
  int htmlCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<Book>> getBookInfo(
    String bookId,
    String hashId, {
    String? title,
  }) async {
    detailCalls++;
    return detail;
  }

  @override
  Future<ApiResponse<Book>> getBookInfoFromHtmlPage(String href) async {
    htmlCalls++;
    if (htmlThrows) throw UnsupportedError('no html channel on this fake');
    final book = htmlBook;
    if (book == null) {
      return ApiResponse.fail(htmlError ?? 'HTTP 513: browser check page');
    }
    return ApiResponse.ok(book);
  }
}

BookIdentifier _id({
  String hash = 'Ej8q7Dmrv9',
  String? href = '/book/Ej8q7Dmrv9/三体.html',
}) => BookIdentifier('26610712', hash, title: '三体', href: href);

void main() {
  Directory? hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('book_detail_html_fb');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir?.delete(recursive: true);
  });

  setUp(() {
    HiveService.settingsBox.clear();
    HiveService.libraryBox.clear();
  });

  ProviderContainer makeContainer(ZLibraryApi api) {
    final container = ProviderContainer(
      overrides: [zlibraryApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('eapi 成功时完全不碰详情页通道', () async {
    final api = _FakeApi(detail: ApiResponse.ok(_eapiBook()));
    final book = await makeContainer(api).read(bookDetailsProvider(_id()).future);
    expect(book.description, 'eapi 正文');
    expect(api.htmlCalls, 0);
  });

  test('短 hash 被拒 → 读详情页正文，路由 href 保留', () async {
    final api = _FakeApi(
      detail: ApiResponse.fail('无效哈希', statusCode: 400),
      htmlBook: _htmlBook(),
    );
    final book = await makeContainer(api).read(bookDetailsProvider(_id()).future);
    expect(book.title, '三体');
    expect(book.description, '详情页正文');
    expect(book.href, '/book/Ej8q7Dmrv9/三体.html');
    // The /dl/ token has to survive onto the detail screen's book, or
    // the download of this book has no address at all.
    expect(book.downloadPath, 'https://zh.z-library.sk/dl/ABVGVr08wz');
    expect(api.detailCalls, 1);
    expect(api.htmlCalls, 1);
  });

  test('详情页正文同样进 7 天缓存：重开零请求', () async {
    final api = _FakeApi(
      detail: ApiResponse.fail('无效哈希', statusCode: 400),
      htmlBook: _htmlBook(),
    );
    final first = await makeContainer(api).read(bookDetailsProvider(_id()).future);
    expect(first.description, '详情页正文');
    expect(api.htmlCalls, 1);

    final second = await makeContainer(api).read(bookDetailsProvider(_id()).future);
    expect(second.description, '详情页正文');
    expect(api.detailCalls, 1, reason: 'eapi 也不再打');
    expect(api.htmlCalls, 1, reason: '详情页也不再抓');
  });

  test('6 位 hash 失败不兜底：错误照旧抛', () async {
    // A real eapi hash that still failed means the book is gone or the
    // session broke. An HTML page would not say otherwise, and the
    // user must see the actual error.
    final api = _FakeApi(
      detail: ApiResponse.fail('book not found', statusCode: 404),
      htmlBook: _htmlBook(),
    );
    await expectLater(
      makeContainer(api).read(bookDetailsProvider(_id(hash: '217fd6')).future),
      throwsA(isA<StateError>()),
    );
    expect(api.htmlCalls, 0);
  });

  test('没有 href 就无从兜底：错误照旧抛', () async {
    final api = _FakeApi(
      detail: ApiResponse.fail('无效哈希', statusCode: 400),
      htmlBook: _htmlBook(),
    );
    await expectLater(
      makeContainer(api).read(bookDetailsProvider(_id(href: null)).future),
      throwsA(isA<StateError>()),
    );
    expect(api.htmlCalls, 0);
  });

  test('详情页通道失败 → 原 eapi 错误仍然是用户看到的那条', () async {
    final api = _FakeApi(
      detail: ApiResponse.fail('无效哈希', statusCode: 400),
      htmlError: 'book detail page failed: not a book page',
    );
    await expectLater(
      () => makeContainer(api).read(bookDetailsProvider(_id()).future),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        '无效哈希',
      )),
    );
    expect(api.htmlCalls, 1);
  });

  test('兜底自己抛异常也不替换原错误', () async {
    final api = _FakeApi(
      detail: ApiResponse.fail('无效哈希', statusCode: 400),
      htmlThrows: true,
    );
    await expectLater(
      () => makeContainer(api).read(bookDetailsProvider(_id()).future),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        '无效哈希',
      )),
    );
  });
}
