import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/storage_service.dart';

/// 详情页的两条腿（[bookDetailsProvider] 正文 +
/// [bookDetailExtrasProvider] 附加字段）：持久缓存新鲜时整段跳过
/// 几百 KB 的 HTML 附加抓取；未命中/过期时两条腿各跑各的、互不
/// 等待；HTML 失败或卡死都只影响附加字段那一侧。全部合成数据，
/// 无网络。
class _FakeDetailApi implements ZLibraryApi {
  /// fetchBookDetailExtras 的返回（null 时失败）。
  BookDetailExtras? extras;

  /// 置为非空后 fetchBookDetailExtras 返回该错误。
  String? extrasError;

  /// 置为 true 后 fetchBookDetailExtras 永不完成（慢链路/卡死的
  /// 那条腿：正文不许被它拖住）。
  bool hangExtras = false;

  /// 置为 true 后 getBookInfo 返回失败（eapi 失败传播用）。
  bool failDetail = false;

  int detailCalls = 0;
  int extrasCalls = 0;

  /// getBookInfo 被调用时 extrasCalls 的值 / 反之——两条腿独立的
  /// 直接证据。
  int extrasCallsWhenDetailStarted = -1;
  int detailCallsWhenExtrasStarted = -1;

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
    detailCallsWhenExtrasStarted = detailCalls;
    if (hangExtras) return Completer<ApiResponse<BookDetailExtras>>().future;
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

Book _detailBook({String? href}) =>
    Book(id: 42, title: '合成书', hash: 'hash42', href: href, author: 'eapi 作者');

BookDetailMetadata _metadata({String volume = '第一卷'}) => BookDetailMetadata(
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

Map<String, dynamic> _staleFields({String volume = '旧版卷'}) => {
  ..._cachedFields(volume: volume),
  'fetchedAt': DateTime.now()
      .subtract(const Duration(days: 8))
      .millisecondsSinceEpoch,
};

ProviderContainer _container(_FakeDetailApi api, _FakeStorage storage) {
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

/// 复刻 [BookDetailScreen] 的组装：两条腿各自读，附加字段到位后
/// 并进正文。先起附加字段那条——它不该等 eapi。
Future<Book> _openBook(ProviderContainer container, BookIdentifier id) async {
  final href = id.href;
  final extrasFuture = (href == null || href.isEmpty)
      ? null
      : container.read(bookDetailExtrasProvider(href).future);
  final book = await container.read(bookDetailsProvider(id).future);
  final json = await extrasFuture;
  return json == null ? book : applyBookDetailExtras(book, json);
}

void main() {
  test('缓存新鲜：整段跳过 HTML 附加抓取，且它不必等 eapi', () async {
    final api = _FakeDetailApi();
    final storage = _FakeStorage()..extrasCache[_pagePath] = _cachedFields();
    final container = _container(api, storage);

    final extrasFuture = container.read(
      bookDetailExtrasProvider(_pagePath).future,
    );
    // 附加字段这一侧全程没碰 eapi：两条腿互不依赖。
    expect(await extrasFuture, isNotNull);
    expect(api.detailCalls, 0);
    expect(api.extrasCalls, 0);
    expect(storage.mergedKeys, isEmpty);

    final book = await _openBook(container, _identifier(href: _pagePath));
    expect(api.detailCalls, 1);
    expect(book.volume, '第一卷');
    expect(book.isbn13, '9780000000002');
    expect(book.ratingInterest, '3.0');
    expect(book.href, _pagePath);
  });

  test('缓存过期：抓取一次并用新值合并、回写缓存', () async {
    final api = _FakeDetailApi()
      ..extras = BookDetailExtras(metadata: _metadata(volume: '新版卷'));
    final storage = _FakeStorage()..extrasCache[_pagePath] = _staleFields();
    final container = _container(api, storage);

    final book = await _openBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, '新版卷');
    expect(storage.mergedKeys, [_pagePath]);
  });

  test('无缓存：附加字段与 eapi 互不等待，两源合并后回写', () async {
    final api = _FakeDetailApi()
      ..extras = BookDetailExtras(metadata: _metadata());
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await _openBook(container, _identifier(href: _pagePath));

    expect(api.detailCalls, 1);
    expect(api.extrasCalls, 1);
    // 互不等待的直接证据：谁都没替谁先跑过对方那一步。
    expect(api.detailCallsWhenExtrasStarted, 0);
    expect(api.extrasCallsWhenDetailStarted, 1);
    expect(book.volume, '第一卷');
    expect(book.author, 'eapi 作者');
    expect(storage.mergedKeys, [_pagePath]);
  });

  test('HTML 失败：附加字段退回过期缓存，不抛', () async {
    final api = _FakeDetailApi()..extrasError = 'HTTP 513: browser check page';
    final storage = _FakeStorage()..extrasCache[_pagePath] = _staleFields();
    final container = _container(api, storage);

    final book = await _openBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, '旧版卷');
    // 失败不回写缓存。
    expect(storage.mergedKeys, isEmpty);
  });

  test('HTML 失败且无缓存：只有附加字段缺席，正文照旧', () async {
    final api = _FakeDetailApi()..extrasError = 'book detail page failed';
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await _openBook(container, _identifier(href: _pagePath));

    expect(api.extrasCalls, 1);
    expect(book.volume, isNull);
    expect(book.author, 'eapi 作者');
  });

  test('HTML 卡死：正文照样到位（不再等那条腿）', () async {
    // 1.5.8~1.6.0 的形态：eapi 已到、HTML 那条 await 不返回，整页
    // 卡在加载。拆分后正文与它无耦合——这个 await 必须能完成。
    final api = _FakeDetailApi()..hangExtras = true;
    final storage = _FakeStorage();
    final container = _container(api, storage);

    // 先把卡死的那条腿发出去，再等正文。
    final extrasFuture = container.read(
      bookDetailExtrasProvider(_pagePath).future,
    );
    unawaited(extrasFuture);

    final book = await container
        .read(bookDetailsProvider(_identifier(href: _pagePath)).future)
        .timeout(const Duration(seconds: 2));

    expect(api.extrasCalls, 1);
    expect(book.author, 'eapi 作者');
    expect(book.volume, isNull);
  });

  test('路由没带 href：正文用 eapi 的 href，附加字段据此定位', () async {
    final api = _FakeDetailApi()
      ..extras = BookDetailExtras(metadata: _metadata());
    final storage = _FakeStorage();
    final container = _container(api, storage);

    final book = await container.read(
      bookDetailsProvider(_identifier()).future,
    );
    expect(book.href, isNull);
    expect(api.extrasCalls, 0);

    // eapi 自己不返 href 时（合成数据如此）正文完整、附加字段缺席；
    // 屏幕改用返回值里的 href 起第二条腿。
    final merged = await _openBook(container, _identifier());
    expect(merged.author, 'eapi 作者');
    expect(merged.volume, isNull);
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
