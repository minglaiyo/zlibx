import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/storage_service.dart';

/// [bookDetailsProvider] 的缓存与并行测试：持久缓存新鲜时整段跳过
/// 几百 KB 的 HTML 附加抓取；未命中/过期时 HTML 与 eapi 并行发起；
/// HTML 失败回退过期缓存。全部合成数据，无网络。
class _FakeDetailApi implements ZLibraryApi {
  /// fetchBookDetailExtras 的返回（null 时失败）。
  BookDetailExtras? extras;

  /// 置为非空后 fetchBookDetailExtras 返回该错误。
  String? extrasError;

  /// 置为 true 后 getBookInfo 返回失败（eapi 失败传播用）。
  bool failDetail = false;

  int detailCalls = 0;
  int extrasCalls = 0;

  /// getBookInfo 被调用那一刻的 extrasCalls——并行发起时应已是 1。
  int extrasCallsWhenDetailStarted = -1;

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
    extrasCallsWhenDetailStarted = extrasCalls;
    if (failDetail) return ApiResponse.fail('detail boom');
    return ApiResponse.ok(_detailBook());
  }

  @override
  Future<ApiResponse<BookDetailExtras>> fetchBookDetailExtras(
    String href,
  ) async {
    extrasCalls++;
    if (extrasError != null) return ApiResponse.fail(extrasError!);
    final extras = this.extras;
    if (extras == null) return ApiResponse.fail('no extras fixture');
    return ApiResponse.ok(extras);
  }
}

class _SignedOutAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoading: false);
}

/// 元数据/附加缓存替身：不碰 Hive，直接内存 Map。
class _FakeStorage extends StorageService {
  Map<String, Map<String, dynamic>> extrasCache = {};
  final List<String> mergedKeys = [];

  @override
  Map<String, dynamic>? getBookDetailExtrasSync(String pagePath) {
    final entry = extrasCache[pagePath];
    return entry == null ? null : Map.of(entry);
  }

  @override
  Future<void> mergeBookDetailExtras(
    String pagePath,
    Map<String, dynamic> fields,
  ) async {
    mergedKeys.add(pagePath);
    extrasCache[pagePath] = {
      ...fields,
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }
}

const _pagePath = '/book/hash42/合成书.html';

Book _detailBook({String? href}) => Book(
      id: 42,
      title: '合成书',
      hash: 'hash42',
      href: href,
      author: 'eapi 作者',
    );

BookDetailMetadata _metadata({String volume = '第一卷'}) =>
    BookDetailMetadata(
      volume: volume,
      isbn13: '9780000000002',
      ipfsCid: 'cid-1',
      ratingInterest: '3.0',
      ratingQuality: '5.0',
    );

Map<String, dynamic> _cachedFields({String volume = '第一卷'}) => {
      'volume': volume,
      'isbn10': null,
      'isbn13': '9780000000002',
      'ipfsCid': 'cid-1',
      'ipfsCidBlake2b': null,
      'ratingInterest': '3.0',
      'ratingQuality': '5.0',
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
    };

ProviderContainer _container(
  _FakeDetailApi api,
  _FakeStorage storage,
) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      storageServiceProvider.overrideWithValue(storage),
      authProvider.overrideWith(_SignedOutAuth.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

BookIdentifier _identifier({String? href}) =>
    BookIdentifier('42', 'hash42', href: href);

Future<Book> _readBook(ProviderContainer container, BookIdentifier id) async {
  return container.read(bookDetailsProvider(id).future);
}

void main() {
  test('缓存新鲜：整段跳过 HTML 附加抓取，eapi 一到即完整', () async {
    final api = _FakeDetailApi();
    final storage = _FakeStorage()
      ..extrasCache[_pagePath] = _cachedFields();
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier(href: _pagePath));

    expect(api.detailCalls, 1);
    expect(api.extrasCalls, 0);
    expect(storage.mergedKeys, isEmpty);
    expect(book.volume, '第一卷');
    expect(book.isbn13, '9780000000002');
    expect(book.ratingInterest, '3.0');
    expect(book.href, _pagePath);
  });

  test('缓存过期：抓取一次并用新值合并、回写缓存', () async {
    final api = _FakeDetailApi()..extras = BookDetailExtras(
        metadata: _metadata(volume: '新版卷'),
      );
    final storage = _FakeStorage()
      ..extrasCache[_pagePath] = {
        ..._cachedFields(volume: '旧版卷'),
        'fetchedAt':
            DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch,
      };
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, '新版卷');
    expect(storage.mergedKeys, [_pagePath]);
  });

  test('无缓存：HTML 与 eapi 并行发起，两源合并后回写', () async {
    final api = _FakeDetailApi()
      ..extras = BookDetailExtras(metadata: _metadata());
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier(href: _pagePath));

    expect(api.detailCalls, 1);
    expect(api.extrasCalls, 1);
    // 并行的直接证据：eapi 开始时 HTML 抓取已经出发。
    expect(api.extrasCallsWhenDetailStarted, 1);
    expect(book.volume, '第一卷');
    expect(book.author, 'eapi 作者');
    expect(storage.mergedKeys, [_pagePath]);
  });

  test('HTML 失败：回退用过期缓存字段，不丢行', () async {
    final api = _FakeDetailApi()..extrasError = 'HTTP 513: browser check page';
    final storage = _FakeStorage()
      ..extrasCache[_pagePath] = {
        ..._cachedFields(volume: '旧版卷'),
        'fetchedAt':
            DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch,
      };
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, '旧版卷');
    // 失败不回写缓存。
    expect(storage.mergedKeys, isEmpty);
  });

  test('HTML 失败且无缓存：返回纯 eapi 书（旧行为）', () async {
    final api = _FakeDetailApi()..extrasError = 'book detail page failed';
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, isNull);
    expect(book.author, 'eapi 作者');
  });

  test('路由与 eapi 都没有 href：不抓 HTML', () async {
    final api = _FakeDetailApi()
      ..extras = BookDetailExtras(metadata: _metadata());
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await _readBook(container, _identifier());

    expect(api.extrasCalls, 0);
    expect(book.volume, isNull);
  });

  test('eapi 失败：照旧抛出（页面显示错误 + 重试）', () async {
    final api = _FakeDetailApi()..failDetail = true;
    final storage = _FakeStorage();
    final container = _container(api, storage);

    await expectLater(
      container.read(bookDetailsProvider(_identifier(href: _pagePath)).future),
      throwsA(isA<StateError>()),
    );
  });
}
