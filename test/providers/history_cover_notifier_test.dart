import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/history_cover_notifier.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

/// [HistoryCoverNotifier] + [isInvalidHistoryCover] tests (plan item 11):
/// cloud history rows whose listed cover is dead fall back to the
/// detail endpoint's cover, once per book per session, at most 3 in
/// flight; failures keep the placeholder.
class _FakeApi implements ZLibraryApi {
  _FakeApi({this.coverById, this.fail = false});

  /// book id -> detail cover (absent means the detail has no cover).
  final Map<String, String>? coverById;

  /// When true every detail request fails.
  final bool fail;

  int getBookInfoCalls = 0;
  final List<String> seenIds = [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<Book>> getBookInfo(
    String bookId,
    String hashId, {
    String? title,
  }) async {
    getBookInfoCalls++;
    seenIds.add(bookId);
    if (fail) return ApiResponse.fail('detail boom', statusCode: 500);
    final cover = coverById?[bookId];
    if (cover == null) return ApiResponse.fail('no cover', statusCode: 404);
    return ApiResponse.ok(
      Book(id: int.parse(bookId), title: title ?? '', cover: cover),
    );
  }
}

Book _book(int id) =>
    Book(id: id, title: 'Book $id', hash: 'hash$id', cover: null);

Future<void> _pump(ProviderContainer container) async {
  // The fake answers synchronously; a few event-loop turns let the
  // queued resolve finish and publish.
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('isInvalidHistoryCover', () {
    test('null and blank are invalid', () {
      expect(isInvalidHistoryCover(null), isTrue);
      expect(isInvalidHistoryCover(''), isTrue);
      expect(isInvalidHistoryCover('   '), isTrue);
    });

    test('collections with an empty directory is invalid', () {
      expect(
        isInvalidHistoryCover('https://x.cdn/collections//abc123.jpg'),
        isTrue,
      );
      expect(isInvalidHistoryCover('collections//abc123.jpg'), isTrue);
    });

    test('the site no-cover placeholder is invalid', () {
      expect(
        isInvalidHistoryCover('/img/cover-not-exists.png'),
        isTrue,
      );
      expect(
        isInvalidHistoryCover(
          'https://1lib.sk/img/cover-not-exists.png',
        ),
        isTrue,
      );
    });

    test('real covers pass', () {
      expect(
        isInvalidHistoryCover(
          'https://x.cdn/collections/12/34/cover.jpg',
        ),
        isFalse,
      );
      expect(
        isInvalidHistoryCover('https://x.cdn/covers100/abc.jpg'),
        isFalse,
      );
    });
  });

  group('HistoryCoverNotifier.resolveCover', () {
    test('detail cover lands in state', () async {
      final api = _FakeApi(
        coverById: {'7': 'https://cover.example/7.jpg'},
      );
      final container = ProviderContainer(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await container
          .read(historyCoverProvider.notifier)
          .resolveCover(_book(7));
      await _pump(container);

      expect(
        container.read(historyCoverProvider)['7'],
        'https://cover.example/7.jpg',
      );
      expect(api.getBookInfoCalls, 1);
      expect(api.seenIds, ['7']);
    });

    test('same book is only resolved once per session', () async {
      final api = _FakeApi(
        coverById: {'7': 'https://cover.example/7.jpg'},
      );
      final container = ProviderContainer(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(historyCoverProvider.notifier);
      await notifier.resolveCover(_book(7));
      await notifier.resolveCover(_book(7));
      await _pump(container);

      expect(api.getBookInfoCalls, 1);
    });

    test('failed resolve keeps the placeholder and does not throw',
        () async {
      final api = _FakeApi(fail: true);
      final container = ProviderContainer(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await container
          .read(historyCoverProvider.notifier)
          .resolveCover(_book(9));
      await _pump(container);

      expect(container.read(historyCoverProvider), isEmpty);
      expect(api.getBookInfoCalls, 1);
    });

    test('book id 0 never issues a request', () async {
      final api = _FakeApi(
        coverById: {'0': 'https://cover.example/0.jpg'},
      );
      final container = ProviderContainer(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await container
          .read(historyCoverProvider.notifier)
          .resolveCover(_book(0));
      await _pump(container);

      expect(api.getBookInfoCalls, 0);
      expect(container.read(historyCoverProvider), isEmpty);
    });
  });
}
