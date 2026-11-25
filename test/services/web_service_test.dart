// Web service: port reporting, singleton, snapshot, routes, path safety,
// reader-asset whitelist. The HTTP transport is a plain Dart HttpServer
// again (the native LanWebServer rewrite was reverted — the socket was
// never the problem, the missing local-network permission was), so
// start/stop really bind a socket here; routing is tested through
// [WebService.handleRequest] directly, and the permission gate is
// tested against a fake `zlibx/local_network` channel.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_task.dart';
import 'package:zlibx/services/txt_to_epub.dart';
import 'package:zlibx/services/web_service.dart';

/// A [WebResponse] with the file bytes materialised, so the route
/// tests read exactly what [_dispatch] would send: the in-memory [body],
/// or the [fileStart]..[fileEnd] slice of [filePath].
class Reply {
  final WebResponse response;
  Reply(this.response);

  int get status => response.status;

  Uint8List get bytes {
    if (response.body != null) return response.body!;
    final path = response.filePath;
    if (path == null) return Uint8List(0);
    final all = File(path).readAsBytesSync();
    final start = response.fileStart ?? 0;
    final end = response.fileEnd ?? all.length - 1;
    if (end < start || all.isEmpty) return Uint8List(0);
    return Uint8List.fromList(all.sublist(start, end + 1));
  }

  String get body => utf8.decode(bytes, allowMalformed: true);

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}

/// A port number for the taken-port fallback test. A real socket
/// binds here, so it must be a free-looking high port.
const int testPort = 45678;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zlibx/local_network');

  late Directory tmp;
  late WebService service;
  late WebSnapshot snapshot;
  late List<MethodCall> channelCalls;

  /// The permission answer the fake native side gives. true = granted
  /// (the default); tests that need a denial override the handler.
  late bool mockPermissionGranted;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('web_service_test');
    File('${tmp.path}/a.epub').writeAsStringSync('EPUB-BYTES-0123456789');
    File('${tmp.path}/b.pdf').writeAsStringSync('PDF-BYTES');
    File('${tmp.path}/c.txt').writeAsStringSync('   \n  '); // un-convertible

    snapshot = WebSnapshot(
      files: [
        WebFile(
          bookId: 1,
          title: 'Epub <Book>',
          author: 'Au',
          extension: 'epub',
          coverUrl: 'https://covers.example/a.jpg',
          sizeLabel: '12.3 MB',
          description:
              'A very long synopsis that keeps going and going and going '
              'and going and going and going and going and going and going '
              'and going past one hundred and twenty characters for sure.',
          publisher: 'Test Press',
          year: 2020,
          pages: 300,
          language: 'en',
          location: '${tmp.path}/a.epub',
        ),
        WebFile(
          bookId: 2,
          title: 'Pdf Book',
          author: '',
          extension: 'pdf',
          location: '${tmp.path}/b.pdf',
        ),
        WebFile(
          bookId: 3,
          title: 'Blank Text',
          author: '',
          extension: 'txt',
          location: '${tmp.path}/c.txt',
        ),
      ],
      library: const [
        WebEntry(
          bookId: 1,
          title: 'On shelf',
          author: '',
          extension: 'epub',
          coverUrl: 'https://covers.example/shelf.jpg',
          fileIndex: 0,
        ),
        WebEntry(
          bookId: 9,
          title: 'Not here',
          author: '',
          extension: 'epub',
          description: 'A shelf book that is not on this phone.',
        ),
      ],
      booklists: const [
        WebBooklist(
          id: '42',
          name: 'My list',
          url: 'https://z-library.example/booklist/42/x',
          count: 9,
          books: [
            WebEntry(
              bookId: 1,
              title: 'In list',
              author: '',
              extension: 'epub',
              fileIndex: 0,
            ),
          ],
        ),
      ],
    );

    service = WebService(
      assetLoader: (path) async => utf8.encode('// $path'),
      txtConverter: TxtToEpub(cacheDir: () async => Directory('${tmp.path}/cache')),
    );

    channelCalls = <MethodCall>[];
    mockPermissionGranted = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          channelCalls.add(call);
          switch (call.method) {
            case 'ensureLocalNetworkPermission':
              return mockPermissionGranted;
            default:
              throw MissingPluginException(call.method);
          }
        });
  });

  tearDown(() async {
    await service.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tmp.deleteSync(recursive: true);
  });

  /// Route a request through the service under test, the way
  /// [_dispatch] does after percent-decoding the path. [path] is
  /// therefore already decoded here (e.g. '..', not '%2e%2e');
  /// [query] is the decoded query string, used by /search.
  Future<Reply> get(
    String path, {
    String method = 'GET',
    Map<String, String>? headers,
    Map<String, String>? query,
  }) async {
    final response = await service.handleRequest(
      method: method,
      path: path,
      query: query ?? const <String, String>{},
      headers: headers ?? const <String, String>{},
    );
    return Reply(response);
  }

  group('lifecycle & port', () {
    test('the fixed port is 8080', () {
      expect(kWebServicePort, 8080);
    });

    test('shared is one instance', () {
      expect(identical(WebService.shared, WebService.shared), isTrue);
    });

    test('start binds and reports its port', () async {
      final got = await service.start(snapshot: snapshot, preferredPort: 0);
      expect(got, greaterThan(0));
      expect(service.port, got);
      expect(service.isRunning, isTrue);
    });

    test('a taken port falls back to a system-chosen port', () async {
      // Hold the preferred port so the service cannot bind it.
      final blocker = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        testPort,
      );
      try {
        final got = await service.start(
          snapshot: snapshot,
          preferredPort: testPort,
        );
        expect(got, isNot(testPort));
        expect(got, greaterThan(0));
        expect(service.port, got);
        expect(service.isRunning, isTrue);
      } finally {
        await blocker.close();
      }
    });

    test('keeps running until stop() and can restart', () async {
      final first = await service.start(snapshot: snapshot, preferredPort: 0);
      // Starting again while running is a no-op (same port).
      expect(await service.start(snapshot: snapshot, preferredPort: 0), first);
      expect((await get('/')).status, 200);

      await service.stop();
      expect(service.isRunning, isFalse);
      expect(service.port, isNull);

      final second = await service.start(
        snapshot: snapshot,
        preferredPort: 0,
      );
      expect(second, greaterThan(0));
      expect((await get('/')).status, 200);
    });

    test('denied local-network permission refuses to start', () async {
      mockPermissionGranted = false;
      await expectLater(
        service.start(snapshot: snapshot, preferredPort: 0),
        throwsA(isA<LocalNetworkPermissionDenied>()),
      );
      expect(service.isRunning, isFalse);
      expect(service.port, isNull);
      // The permission was asked exactly once, and no server was bound.
      expect(
        channelCalls.where((c) => c.method == 'ensureLocalNetworkPermission'),
        hasLength(1),
      );
    });

    test('granted local-network permission starts normally', () async {
      final got = await service.start(snapshot: snapshot, preferredPort: 0);
      expect(got, greaterThan(0));
      expect(service.isRunning, isTrue);
      expect(
        channelCalls.where((c) => c.method == 'ensureLocalNetworkPermission'),
        hasLength(1),
      );
    });
  });

  group('snapshot', () {
    test('counts, shelf linking and filtering of unfinished tasks', () {
      final done = DownloadTask(
        id: '1',
        book: const Book(
          id: 1,
          title: 'One',
          author: 'A',
          extension: 'epub',
          cover: 'https://covers.example/task.jpg',
          description: 'A synopsis.',
          publisher: 'Test Press',
          year: 2020,
          pages: 300,
          language: 'en',
          filesize: 9999,
        ),
        status: DownloadStatus.completed,
        filePath: '/x/one.epub',
        fileSize: 1536,
      );
      final missing = DownloadTask(
        id: '2',
        book: const Book(id: 2, title: 'Two', extension: 'pdf'),
        status: DownloadStatus.completed,
        filePath: '/x/two.pdf',
        missingFile: true,
      );
      final running = DownloadTask(
        id: '3',
        book: const Book(id: 9, title: 'Nine', extension: 'epub'),
        status: DownloadStatus.downloading,
        filePath: '/x/nine.epub',
      );
      final snap = WebSnapshot.build(
        tasks: [done, missing, running],
        saved: const [
          Book(
            id: 1,
            title: 'One',
            extension: 'epub',
            cover: 'https://covers.example/saved.jpg',
          ),
          Book(id: 9, title: 'Nine', extension: 'epub'),
        ],
        booklists: const [
          Booklist(
            id: '7',
            name: 'L',
            url: 'https://z.example/booklist/7',
            count: 3,
            previewBooks: [
              Book(id: 1, title: 'One', cover: 'https://covers.example/preview.jpg'),
              Book(id: 8, title: 'Eight'),
            ],
          ),
        ],
      );
      expect(snap.downloadedCount, 1);
      expect(snap.libraryCount, 2);
      expect(snap.booklistCount, 1);
      expect(snap.library[0].fileIndex, 0);
      expect(snap.library[1].fileIndex, isNull);
      expect(snap.booklists.single.books[0].fileIndex, 0);
      expect(snap.booklists.single.books[1].fileIndex, isNull);
      expect(snap.files.single.extension, 'epub');
      // Covers flow from the book into the file and every entry.
      expect(snap.files.single.coverUrl, 'https://covers.example/task.jpg');
      expect(snap.library[0].coverUrl, 'https://covers.example/saved.jpg');
      expect(snap.library[1].coverUrl, isNull);
      expect(
        snap.booklists.single.books[0].coverUrl,
        'https://covers.example/preview.jpg',
      );
      expect(snap.booklists.single.books[1].coverUrl, isNull);
      // Items 1/4/5: the book id, the real file size (the task's own
      // byte count wins over the book's server-reported size), the
      // synopsis and the detail metadata flow into the file and the
      // entries.
      expect(snap.files.single.bookId, 1);
      expect(snap.files.single.sizeLabel, '1.5 KB');
      expect(snap.files.single.description, 'A synopsis.');
      expect(snap.files.single.publisher, 'Test Press');
      expect(snap.files.single.year, 2020);
      expect(snap.files.single.pages, 300);
      expect(snap.files.single.language, 'en');
      expect(snap.library[0].bookId, 1);
      expect(snap.library[0].sizeLabel, '1.5 KB');
      // Item 3: a book with a running download is marked pending,
      // so the web page offers no second trigger link for it.
      expect(snap.pendingBookIds, contains(9));
      expect(snap.library[1].downloadPending, isTrue);
      expect(snap.library[1].fileIndex, isNull);
    });
  });

  group('home page and downloads', () {
    setUp(() async {
      await service.start(snapshot: snapshot, preferredPort: 0);
    });

    test('three sections, links, escaping, and no JavaScript', () async {
      final r = await get('/');
      expect(r.status, 200);
      // Sidebar, after Legado's bookshelf: title, poem, a working
      // search form, recent reading and settings sections, GitHub.
      expect(r.body, contains('class="sidebar"'));
      expect(r.body, contains('清风不识字，何故乱翻书'));
      expect(
        r.body,
        contains('<form class="search" method="get" action="/search">'),
      );
      expect(r.body, contains('name="q"'));
      expect(r.body, contains('最近阅读'));
      expect(r.body, contains('尚无阅读记录'));
      expect(r.body, contains('基本设定'));
      expect(r.body, contains('已连接'));
      expect(r.body, contains('https://github.com/minglaiyo/zlibx'));
      // No dark banner, no three-button section navigation.
      expect(r.body, isNot(contains('class="banner"')));
      expect(r.body, isNot(contains('href="#downloaded"')));
      expect(r.body, isNot(contains('href="#library"')));
      expect(r.body, isNot(contains('href="#booklists"')));
      // Book cards in a grid, not a plain list; borderless, no badge.
      expect(r.body, contains('class="grid"'));
      expect(r.body, contains('class="card"'));
      expect(r.body, isNot(contains('<ul')));
      expect(r.body, isNot(contains('border:1px solid #ddd')));
      expect(r.body, isNot(contains('class="badge"')));
      // Covers: the EPUB has one, the PDF falls back to a
      // first-letter tile ('Pdf Book' -> 'P').
      expect(
        r.body,
        contains('<img class="cover" src="https://covers.example/a.jpg"'),
      );
      expect(r.body, contains('src="https://covers.example/shelf.jpg"'));
      expect(r.body, contains('class="cover-ph"'));
      expect(r.body, contains('>P</div>'));
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('href="/read/0"'));
      expect(r.body, contains('href="/download/1"'));
      // PDF reads in the browser's own viewer via /book, not /read.
      expect(r.body, contains('href="/book/1"'));
      expect(r.body, isNot(contains('href="/read/1"')));
      expect(r.body, contains('href="/booklist/42"'));
      expect(r.body, contains('Epub &lt;Book&gt;')); // escaped
      expect(r.body.toLowerCase(), isNot(contains('<script')));
      expect(r.body, contains('(3)')); // downloaded section count
      // Item 8: the app icon is linked in the head.
      expect(r.body, contains('rel="icon"'));
      expect(r.body, contains('href="/icon.png"'));
      // Item 1: the file size sits next to the download link.
      expect(r.body, contains('12.3 MB'));
      // Item 4: the card shows the truncated description, not the
      // whole synopsis.
      expect(r.body, contains('class="desc"'));
      expect(r.body, contains('A very long synopsis'));
      expect(r.body, contains('…'));
      expect(r.body, isNot(contains('past one hundred and twenty')));
      // Item 3: an undownloaded library book gets the trigger link.
      expect(r.body, contains('href="/request-download/9"'));
      expect(r.body, contains('下载到手机'));
      // Item 7: the booklist card shows how many are downloaded.
      expect(r.body, contains('已下载 1 / 共 9 本'));
      // Item 2: the downloaded section offers a pack-all button.
      expect(r.body, contains('href="/zip/all"'));
      expect(r.body, contains('全部打包'));
    });

    test('search filters by title and author, case-insensitively', () async {
      // "epub" matches only the EPUB's title.
      final byTitle = await get('/search', query: {'q': 'EPUB'});
      expect(byTitle.status, 200);
      expect(byTitle.body, contains('Epub &lt;Book&gt;'));
      expect(byTitle.body, isNot(contains('Pdf Book')));
      expect(byTitle.body, isNot(contains('Blank Text')));
      // "book" matches both book titles.
      final both = await get('/search', query: {'q': 'book'});
      expect(both.body, contains('Epub &lt;Book&gt;'));
      expect(both.body, contains('Pdf Book'));
      // "au" matches the EPUB's author.
      final byAuthor = await get('/search', query: {'q': 'au'});
      expect(byAuthor.body, contains('Epub &lt;Book&gt;'));
      expect(byAuthor.body, isNot(contains('Pdf Book')));
      // A library row that points at a matched file is not doubled.
      final shelf = await get('/search', query: {'q': 'shelf'});
      expect(shelf.body, contains('On shelf'));
      expect(shelf.body, contains('href="/download/0"'));
      expect(shelf.body, contains('href="/read/0"'));
      // The search page shows the term, a way home, and the sidebar
      // with the query prefilled.
      expect(byTitle.body, contains('搜索“EPUB”'));
      expect(byTitle.body, contains('Back to home'));
      expect(byTitle.body, contains('value="EPUB"'));
      expect(byTitle.body, contains('class="sidebar"'));
    });

    test('search with no match or no query shows the empty state', () async {
      final none = await get('/search', query: {'q': 'zzz'});
      expect(none.status, 200);
      expect(none.body, contains('Nothing here'));
      expect(none.body, contains('搜索“zzz”'));

      final empty = await get('/search');
      expect(empty.status, 200);
      expect(empty.body, contains('Nothing here'));
    });

    test('a file downloads byte for byte, straight from its path', () async {
      final r = await get('/download/0');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
      expect(r.header('content-disposition'), contains('attachment'));
      expect(r.header('content-length'), '21');
      expect(r.header('accept-ranges'), 'bytes');
    });

    test('Range requests resume', () async {
      final r = await get('/download/0', headers: {'Range': 'bytes=5-9'});
      expect(r.status, 206);
      expect(r.body, 'BYTES');
      expect(r.header('content-range'), 'bytes 5-9/21');
      expect(r.header('content-length'), '5');
    });

    test('Range suffix and open-ended forms', () async {
      final suffix = await get('/download/0', headers: {'Range': 'bytes=-5'});
      expect(suffix.status, 206);
      expect(suffix.body, '56789');
      expect(suffix.header('content-range'), 'bytes 16-20/21');

      final open = await get('/download/0', headers: {'Range': 'bytes=20-'});
      expect(open.status, 206);
      expect(open.body, '9');
      expect(open.header('content-range'), 'bytes 20-20/21');
    });

    test('an unsatisfiable Range is a 416 with the length', () async {
      for (final range in ['bytes=99-100', 'bytes=21-']) {
        final r = await get('/download/0', headers: {'Range': range});
        expect(r.status, 416, reason: range);
        expect(r.header('content-range'), 'bytes */21');
        expect(r.body, isEmpty);
      }
    });

    test('HEAD returns the same headers as GET; Kotlin drops the body', () async {
      final getR = await get('/download/0');
      final headR = await get('/download/0', method: 'HEAD');
      expect(headR.status, 200);
      expect(headR.header('content-length'), getR.header('content-length'));
      // The descriptor still carries the file — it is Kotlin, not
      // Dart, that skips the body for HEAD.
      expect(headR.response.filePath, isNotNull);
      expect(headR.response.fileStart, 0);
      expect(headR.response.fileEnd, 20);
    });

    test('booklist page lists preview books and the official link', () async {
      final r = await get('/booklist/42');
      expect(r.status, 200);
      expect(r.body, contains('In list'));
      expect(r.body, contains('class="grid"'));
      expect(r.body, contains('class="sidebar"'));
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('https://z-library.example/booklist/42/x'));
      // Item 2: a downloaded book in the list means a pack button.
      expect(r.body, contains('href="/zip/booklist/42"'));
      expect(r.body, contains('打包下载'));
    });

    test('out-of-range indexes and odd paths 404 without crashing', () async {
      // Paths are already percent-decoded here (Kotlin decodes before
      // Dart sees them), so '..' arrives as '..'.
      for (final path in [
        '/download/3',
        '/download/999999999',
        '/download/-1',
        '/download/abc',
        '/download/0/extra',
        '/download/../../etc/passwd',
        '/download/../a.epub',
        '/download/${tmp.path}/a.epub',
        '/read/7',
        '/read/x',
        '/book/7',
        '/booklist/nope',
        '/booklist/42/more',
        '/nothing',
      ]) {
        final r = await get(path);
        expect(r.status, 404, reason: path);
      }
      // The service is still alive afterwards.
      expect((await get('/')).status, 200);
    });

    test('non-GET methods are refused', () async {
      final r = await get('/', method: 'POST');
      expect(r.status, 405);
      expect(r.body, 'Method Not Allowed');
    });
  });

  group('reader routes', () {
    setUp(() async {
      await service.start(snapshot: snapshot, preferredPort: 0);
    });

    test('/read serves the reader page for a readable book', () async {
      final r = await get('/read/0');
      expect(r.status, 200);
      expect(r.body, contains('/reader-assets/view.js'));
      expect(r.body, contains('"/book/0"'));
    });

    test('PDF has no foliate read page, but /book serves it inline', () async {
      expect((await get('/read/1')).status, 404);
      final r = await get('/book/1');
      expect(r.status, 200);
      expect(r.body, 'PDF-BYTES');
      expect(r.header('content-type'), 'application/pdf');
      // No attachment: the browser's own PDF viewer opens it.
      expect(r.header('content-disposition'), isNull);
      expect(r.header('x-book-name'), 'book.pdf');
    });

    test('/book returns the raw bytes of an EPUB', () async {
      final r = await get('/book/0');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
      expect(r.header('x-book-name'), 'book.epub');
    });

    test('/book supports Range too', () async {
      final r = await get('/book/0', headers: {'Range': 'bytes=5-9'});
      expect(r.status, 206);
      expect(r.body, 'BYTES');
      expect(r.header('content-range'), 'bytes 5-9/21');
      expect(r.header('x-book-name'), 'book.epub');
    });

    test('an unconvertible TXT gives a readable page, not a crash', () async {
      final r = await get('/read/2');
      expect(r.status, 422);
      expect(r.body, contains('<html'));
      expect((await get('/')).status, 200);
      // Its download link is unaffected.
      expect((await get('/download/2')).status, 200);
    });

    test('an unconvertible TXT is a plain 422 on /book', () async {
      final r = await get('/book/2');
      expect(r.status, 422);
      expect(r.body, 'convert failed');
    });

    test('/reader-assets serves only the whitelist', () async {
      for (final name in kReaderAssetWhitelist) {
        final r = await get('/reader-assets/$name');
        expect(r.status, 200, reason: name);
      }
      expect(kReaderAssetWhitelist.length, 13);
      for (final path in [
        '/reader-assets/pdf.js',
        '/reader-assets/search.js',
        '/reader-assets/vendor/pdfjs/pdf.js',
        '/reader-assets/reader.html',
        '/reader-assets/../pubspec.yaml',
        '/reader-assets/vendor/',
        '/reader-assets/',
        '/reader-assets',
      ]) {
        final r = await get(path);
        expect(r.status, 404, reason: path);
      }
    });

    test('a whitelisted but not-yet-vendored file is a clean 404', () async {
      final empty = WebService(assetLoader: (_) async => null);
      addTearDown(empty.stop);
      await empty.start(snapshot: snapshot, preferredPort: 0);
      final r = await empty.handleRequest(method: 'GET', path: '/reader-assets/view.js');
      expect(r.status, 404);
    });
  });

  group('detail page, zip, request-download, booklist pages, icon', () {
    test('formatFileSize and truncateDescription', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(12 * 1024 * 1024 + 300 * 1024), '12.3 MB');
      expect(formatFileSize(2 * 1024 * 1024 * 1024), '2.0 GB');
      expect(truncateDescription('short'), 'short');
      final long = 'x' * 200;
      expect(truncateDescription(long).length, 121);
      expect(truncateDescription(long), endsWith('…'));
    });

    test('detail page shows the full synopsis and metadata', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final r = await get('/detail/1');
      expect(r.status, 200);
      // The full description, not the 120-char truncation.
      expect(r.body, contains('past one hundred and twenty characters'));
      expect(r.body, contains('Test Press'));
      expect(r.body, contains('2020'));
      expect(r.body, contains('300'));
      expect(r.body, contains('12.3 MB'));
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('href="/read/0"'));
      // An undownloaded book shows "not downloaded" plus the trigger.
      final missing = await get('/detail/9');
      expect(missing.status, 200);
      expect(missing.body, contains('A shelf book that is not on this phone.'));
      expect(missing.body, contains('href="/request-download/9"'));
      expect((await get('/detail/999')).status, 404);
      expect((await get('/detail/abc')).status, 404);
    });

    test('zip routes pack the files and attach them', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final all = await get('/zip/all');
      expect(all.status, 200);
      expect(all.header('content-type'), 'application/zip');
      expect(
        all.header('content-disposition'),
        contains('attachment; filename="downloaded-books.zip"'),
      );
      expect(all.response.body, isNotNull);
      expect(all.response.body!.length, greaterThan(0));
      // A zip stores file names in plain text (the entry name is
      // "Title - Author.ext", with unsafe characters replaced).
      expect(all.body, contains('Au.epub'));
      expect(all.body, contains('Pdf Book.pdf'));
      expect(all.body, contains('Blank Text.txt'));
      // A booklist zip packs only that list's downloaded books.
      final list = await get('/zip/booklist/42');
      expect(list.status, 200);
      expect(list.header('content-type'), 'application/zip');
      expect(list.body, contains('Au.epub'));
      expect(list.body, isNot(contains('Pdf Book.pdf')));
      expect((await get('/zip/booklist/nope')).status, 404);
      expect((await get('/zip/other')).status, 404);
    });

    test('request-download calls the callback and confirms', () async {
      final calls = <int>[];
      final svc = WebService(
        assetLoader: (path) async => utf8.encode('// $path'),
        txtConverter: TxtToEpub(cacheDir: () async => Directory('${tmp.path}/cache')),
      );
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        onRequestDownload: (id) async {
          calls.add(id);
          return WebDownloadRequest.started;
        },
      );
      final r = Reply(
        await svc.handleRequest(method: 'GET', path: '/request-download/9'),
      );
      expect(r.status, 200);
      expect(calls, [9]);
      expect(r.body, contains('已开始下载'));
      expect(r.body, contains('重启 Web 服务'));
      expect(r.body, contains('下载额度'));
      expect(
        (await svc.handleRequest(
          method: 'GET',
          path: '/request-download/abc',
        )).status,
        404,
      );
    });

    test('request-download reports an already-downloading book', () async {
      final svc = WebService(
        assetLoader: (path) async => utf8.encode('// $path'),
        txtConverter: TxtToEpub(cacheDir: () async => Directory('${tmp.path}/cache')),
      );
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        onRequestDownload: (_) async =>
            WebDownloadRequest.alreadyDownloading,
      );
      final r = Reply(
        await svc.handleRequest(method: 'GET', path: '/request-download/9'),
      );
      expect(r.status, 200);
      expect(r.body, contains('正在下载中'));
      expect(r.body, isNot(contains('已开始下载')));
    });

    test('booklist page 2 comes from the fetcher, page 1 falls back', () async {
      final svc = WebService(
        assetLoader: (path) async => utf8.encode('// $path'),
        txtConverter: TxtToEpub(cacheDir: () async => Directory('${tmp.path}/cache')),
      );
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        onFetchBooklistPage: (id, page) async {
          if (id != '42') return null;
          if (page == 1) return null; // simulate a failed fetch
          return WebBooklistPage(
            books: const [
              Book(id: 1, title: 'Page two one', extension: 'epub'),
              Book(id: 77, title: 'Page two two', extension: 'epub'),
            ],
            hasMore: true,
          );
        },
      );
      // Page 2: the live books, a prev link and a next link.
      final page2 = Reply(
        await svc.handleRequest(
          method: 'GET',
          path: '/booklist/42',
          query: {'page': '2'},
        ),
      );
      expect(page2.status, 200);
      expect(page2.body, contains('Page two one'));
      expect(page2.body, contains('Page two two'));
      expect(page2.body, contains('上一页'));
      expect(page2.body, contains('下一页'));
      expect(page2.body, contains('第 2 页'));
      expect(page2.body, isNot(contains('In list')));
      // The downloaded book on the live page gets its links.
      expect(page2.body, contains('href="/download/0"'));
      // The undownloaded one gets the trigger link.
      expect(page2.body, contains('href="/request-download/77"'));
      // Page 1 with a failed fetch falls back to the preview books.
      final page1 = Reply(
        await svc.handleRequest(method: 'GET', path: '/booklist/42'),
      );
      expect(page1.status, 200);
      expect(page1.body, contains('In list'));
      expect(page1.body, contains('加载失败'));
      expect(page1.body, isNot(contains('下一页')));
    });

    test('icon routes serve the app icon as PNG', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      for (final path in ['/icon.png', '/favicon.ico']) {
        final r = await get(path);
        expect(r.status, 200, reason: path);
        expect(r.header('content-type'), 'image/png');
        expect(r.response.body, isNotNull);
        expect(r.response.body, isNotEmpty);
        // The embedded base64 really decodes to a PNG (192x192
        // launcher icon): PNG magic bytes 89 50 4E 47.
        final bytes = r.bytes;
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      }
    });
  });
}
