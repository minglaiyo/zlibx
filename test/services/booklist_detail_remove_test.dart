import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/booklist_detail_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

/// [BooklistDetailController.removeBook] flow tests.
///
/// remove-book takes the readlist ENTRY id (the per-(book, list)
/// membership-row id from `current-user`), never the book id — sending
/// the book id is what the server 500s on (verified live 2026-11-09:
/// 白鹿原 book 11959979 in 001 carries entry 161213534; the website's
/// own remove for 嘎嘎嘎 sent 161286730).
///
/// fake only implements the methods this controller path uses; any
/// other call throws.
class _FakeZLibraryApi implements ZLibraryApi {
  int? entryId = 161213534;
  bool failEntryFetch = false;
  int getReadlistBookIdCalls = 0;
  int? lastReadlistBooklistId;
  int? lastReadlistBookId;
  int removeCalls = 0;
  int? lastRemoveBooklistId;
  int? lastRemoveEntryId;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<List<Book>>> getBooklistDetailBooks(
    Booklist list,
  ) async {
    return ApiResponse.ok(const [
      Book(id: 11959979, title: '白鹿原'),
      Book(id: 3658844, title: '曾国藩传'),
    ]);
  }

  @override
  Future<ApiResponse<int?>> getReadlistBookId({
    required int booklistId,
    required int bookId,
  }) async {
    getReadlistBookIdCalls++;
    lastReadlistBooklistId = booklistId;
    lastReadlistBookId = bookId;
    if (failEntryFetch) return ApiResponse.fail('network error');
    return ApiResponse.ok(entryId);
  }

  @override
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    removeCalls++;
    lastRemoveBooklistId = booklistId;
    lastRemoveEntryId = readlistBookId;
    return ApiResponse.ok(true);
  }
}

const _args = BooklistDetailArgs(
  booklist: Booklist(
    id: '4088695',
    name: '001',
    url: 'https://zh.z-library.sk/booklist/4088695/62a0c2/001.html',
  ),
  canEdit: true,
);

const _book = Book(id: 11959979, title: '白鹿原');

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('booklist_remove');
    Hive.init(tempDir.path);
    await Hive.openLazyBox(BooklistHtmlCache.boxName);
  });

  setUp(() async {
    await Hive.lazyBox(BooklistHtmlCache.boxName).clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  /// Loads the controller with the fake page (two books) and waits for
  /// the microtask-started loadFirst to finish.
  Future<ProviderContainer> loadedContainer(_FakeZLibraryApi api) async {
    final container = ProviderContainer(
      overrides: [zlibraryApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    // A listener keeps the autoDispose controller alive for the test.
    container.listen(booklistDetailControllerProvider(_args), (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [11959979, 3658844],
    );
    return container;
  }

  test('remove resolves the entry id and removes with it', () async {
    final api = _FakeZLibraryApi();
    final container = await loadedContainer(api);

    final response = await container
        .read(booklistDetailControllerProvider(_args).notifier)
        .removeBook(_book);

    expect(response.success, isTrue);
    expect(api.getReadlistBookIdCalls, 1);
    expect(api.lastReadlistBooklistId, 4088695);
    expect(api.lastReadlistBookId, 11959979);
    expect(api.removeCalls, 1);
    expect(api.lastRemoveBooklistId, 4088695);
    expect(api.lastRemoveEntryId, 161213534);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [3658844],
    );
  });

  test('remove is never called when the entry id is null', () async {
    final api = _FakeZLibraryApi()..entryId = null;
    final container = await loadedContainer(api);

    final response = await container
        .read(booklistDetailControllerProvider(_args).notifier)
        .removeBook(_book);

    expect(response.success, isFalse);
    expect(api.getReadlistBookIdCalls, 1);
    expect(api.removeCalls, 0);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [11959979, 3658844],
    );
  });

  test('remove is never called when resolving the entry id fails', () async {
    final api = _FakeZLibraryApi()..failEntryFetch = true;
    final container = await loadedContainer(api);

    final response = await container
        .read(booklistDetailControllerProvider(_args).notifier)
        .removeBook(_book);

    expect(response.success, isFalse);
    expect(response.error, 'network error');
    expect(api.getReadlistBookIdCalls, 1);
    expect(api.removeCalls, 0);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [11959979, 3658844],
    );
  });
}
