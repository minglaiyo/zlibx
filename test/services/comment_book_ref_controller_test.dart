
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/screens/account/comment_book_ref_controller.dart';

/// [CommentBookRefController] 的行为测试：预取去重、上限、单本失败
/// 继续跑、跳详情缓存命中 / 现场反查 / 防重点 / 失败回调。
///
/// fake 的 search 约定：书名传 "Book #`<id>`"，按 id 回应同 id 的
/// [Book]（hash/cover 都带上）——[resolveCommentBookRef] 是按
/// `book.id == bookId` 匹配的，与真实接口的匹配方式一致。
class _FakeZLibraryApi implements ZLibraryApi {
  _FakeZLibraryApi({this.failBookIds = const {}, this.delay});

  /// 出现在这里的 bookId，search 时抛异常（模拟网络失败）。
  final Set<int> failBookIds;

  /// 每次人为延迟，用于并发/防重点测试。
  final Duration? delay;

  int searchCalls = 0;
  final List<int> searchedBookIds = [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<List<Book>>> search({
    String? message,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int? page,
    int? limit,
    // Kept in sync with ZLibraryApiBase.search (exact-match flag,
    // added by the search filter page; cancel token, added by the
    // SearchNotifier) — the fake ignores both.
    bool? exact,
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    if (delay != null) await Future<void>.delayed(delay!);
    final id = int.parse(message!.split('#').last);
    if (failBookIds.contains(id)) throw StateError('search failed');
    searchedBookIds.add(id);
    return ApiResponse.ok([
      Book(
        id: id,
        title: message,
        hash: 'hash-$id',
        cover: 'cover-$id',
      ),
    ]);
  }
}

({int bookId, String title}) _item(int id) =>
    (bookId: id, title: 'Book #$id');

void main() {
  test('prefetch 去重：同一 bookId 只搜一次', () async {
    final api = _FakeZLibraryApi();
    final controller = CommentBookRefController(api: api);
    await controller.prefetch([_item(1), _item(1), _item(1)]);
    expect(api.searchCalls, 1);
    expect(controller.refFor(1)?.hash, 'hash-1');
    controller.dispose();
  });

  test('prefetch 上限：只搜前 maxPrefetch 本', () async {
    final api = _FakeZLibraryApi();
    final controller = CommentBookRefController(api: api);
    final items = List.generate(60, _item);
    await controller.prefetch(items);
    expect(api.searchCalls, CommentBookRefController.maxPrefetch);
    controller.dispose();
  });

  test('prefetch 单本失败不阻塞其余', () async {
    final api = _FakeZLibraryApi(failBookIds: {2, 3});
    final controller = CommentBookRefController(api: api);
    await controller.prefetch([_item(1), _item(2), _item(3), _item(4)]);
    // 失败的 2、3 不出现在 searchedBookIds（抛异常前不记录），
    // 其余全部解析成功。
    expect(controller.refFor(1)?.hash, 'hash-1');
    expect(controller.refFor(4)?.hash, 'hash-4');
    expect(controller.refs.containsKey(2), isFalse);
    expect(api.searchCalls, 4);
    controller.dispose();
  });

  test('openBookDetail 缓存命中：不再发起搜索', () async {
    final api = _FakeZLibraryApi();
    final controller = CommentBookRefController(api: api);
    await controller.prefetch([_item(7)]);
    final before = api.searchCalls;
    Book? received;
    var failed = false;
    final opened = await controller.openBookDetail(
      bookId: 7,
      title: 'Book #7',
      onReady: (book) => received = book,
      onFail: () => failed = true,
    );
    expect(opened, isTrue);
    expect(failed, isFalse);
    expect(api.searchCalls, before);
    expect(received?.id, 7);
    expect(received?.hash, 'hash-7');
    // 跳转完成后不再处于"解析中"。
    expect(controller.isOpening(7), isFalse);
    controller.dispose();
  });

  test('openBookDetail 现场反查：成功后写入缓存', () async {
    final api = _FakeZLibraryApi();
    final controller = CommentBookRefController(api: api);
    var failed = false;
    final opened = await controller.openBookDetail(
      bookId: 9,
      title: 'Book #9',
      onReady: (_) {},
      onFail: () => failed = true,
    );
    expect(opened, isTrue);
    expect(failed, isFalse);
    expect(api.searchCalls, 1);
    expect(controller.refFor(9)?.hash, 'hash-9');
    controller.dispose();
  });

  test('openBookDetail 失败：onFail 回调且不导航', () async {
    final api = _FakeZLibraryApi(failBookIds: {5});
    final controller = CommentBookRefController(api: api);
    var failed = false;
    Book? received;
    final opened = await controller.openBookDetail(
      bookId: 5,
      title: 'Book #5',
      onReady: (book) => received = book,
      onFail: () => failed = true,
    );
    expect(opened, isFalse);
    expect(failed, isTrue);
    expect(received, isNull);
    expect(controller.isOpening(5), isFalse);
    controller.dispose();
  });

  test('openBookDetail 防重点：解析中重复点击直接拒绝', () async {
    final api = _FakeZLibraryApi(delay: const Duration(milliseconds: 50));
    final controller = CommentBookRefController(api: api);
    // 第一次点击未 await（还在解析中），立刻再点第二次。
    final first = controller.openBookDetail(
      bookId: 11,
      title: 'Book #11',
      onReady: (_) {},
      onFail: () {},
    );
    final second = await controller.openBookDetail(
      bookId: 11,
      title: 'Book #11',
      onReady: (_) {},
      onFail: () {},
    );
    expect(second, isFalse);
    await first;
    expect(api.searchCalls, 1);
    controller.dispose();
  });

  test('dispose 后 emit 不再通知 listener', () async {
    final api = _FakeZLibraryApi();
    var notified = 0;
    final controller = CommentBookRefController(api: api)
      ..addListener(() => notified++);
    controller.dispose();
    await controller.prefetch([_item(1)]);
    await controller.openBookDetail(
      bookId: 2,
      title: 'Book #2',
      onReady: (_) {},
      onFail: () {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(notified, 0);
  });
}
