// Web service: port reporting, singleton, snapshot, routes, path safety,
// reader-asset whitelist. The HTTP transport is a plain Dart HttpServer
// again (the native LanWebServer rewrite was reverted — the socket was
// never the problem, the missing local-network permission was), so
// start/stop really bind a socket here; routing is tested through
// [WebService.handleRequest] directly, and the permission gate is
// tested against a fake `zlibx/local_network` channel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_task.dart';
import 'package:zlibx/services/reader_formats.dart';
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
    );

    service = WebService(
      requireAccessToken: false,
      assetLoader: (path) async => utf8.encode('// $path'),
      txtConverter: TxtToEpub(
        cacheDir: () async => Directory('${tmp.path}/cache'),
      ),
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
    String? body,
  }) async {
    final response = await service.handleRequest(
      method: method,
      path: path,
      query: query ?? const <String, String>{},
      headers: headers ?? const <String, String>{},
      body: body,
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

    test(
      'the HTTP transport enforces tokens and streams Range responses',
      () async {
        final svc = WebService(requireAccessToken: true);
        addTearDown(svc.stop);
        final port = await svc.start(snapshot: snapshot, preferredPort: 0);
        final token = svc.accessToken!;
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final base = Uri.parse('http://127.0.0.1:$port');

        final deniedRequest = await client.getUrl(base.resolve('/download/1'));
        final denied = await deniedRequest.close();
        expect(denied.statusCode, HttpStatus.unauthorized);
        expect(denied.headers.value('referrer-policy'), 'no-referrer');
        await denied.drain<void>();

        final rangeRequest = await client.getUrl(
          base.resolve('/download/1?t=${Uri.encodeQueryComponent(token)}'),
        );
        rangeRequest.headers.set('Range', 'bytes=5-9');
        final range = await rangeRequest.close();
        expect(range.statusCode, HttpStatus.partialContent);
        expect(range.headers.value('content-range'), 'bytes 5-9/21');
        expect(
          (await range.toList()).expand((chunk) => chunk),
          'BYTES'.codeUnits,
        );

        final headRequest = await client.openUrl(
          'HEAD',
          base.resolve('/api/library'),
        );
        headRequest.headers.set('Authorization', 'Bearer $token');
        final head = await headRequest.close();
        expect(head.statusCode, HttpStatus.ok);
        expect(head.headers.value('content-length'), isNotNull);
        expect(await head.toList(), isEmpty);
      },
    );

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

      final second = await service.start(snapshot: snapshot, preferredPort: 0);
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
      );
      expect(snap.downloadedCount, 1);
      expect(snap.libraryCount, 2);
      expect(snap.library[0].fileIndex, 0);
      expect(snap.library[1].fileIndex, isNull);
      expect(snap.files.single.extension, 'epub');
      // Covers flow from the book into the file and every entry.
      expect(snap.files.single.coverUrl, 'https://covers.example/task.jpg');
      expect(snap.library[0].coverUrl, 'https://covers.example/saved.jpg');
      expect(snap.library[1].coverUrl, isNull);
      // Items 1/4: the book id, the real file size (the task's own
      // byte count wins over the book's server-reported size) and the
      // synopsis flow into the file and the entries.
      expect(snap.files.single.bookId, 1);
      expect(snap.files.single.sizeLabel, '1.5 KB');
      expect(snap.files.single.description, 'A synopsis.');
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

    test('two sections, links, escaping, and no JavaScript', () async {
      final r = await get('/');
      expect(r.status, 200);
      // No sidebar any more: no title/poem/settings/GitHub column.
      // The poem sits at the top of the main area, and the search
      // box shares the downloads heading row, right end.
      expect(r.body, isNot(contains('class="sidebar"')));
      expect(r.body, isNot(contains('基本设定')));
      expect(r.body, isNot(contains('已连接')));
      expect(r.body, isNot(contains('github.com/minglaiyo/zlibx')));
      expect(r.body, contains('class="poem"'));
      expect(r.body, contains('邂逅相遇，适我愿兮'));
      expect(
        r.body.indexOf('邂逅相遇，适我愿兮'),
        lessThan(r.body.indexOf('id="downloaded"')),
      );
      expect(r.body, contains('class="head-row"'));
      expect(
        r.body,
        contains('<form class="search" method="get" action="/search">'),
      );
      expect(r.body, contains('name="q"'));
      expect(
        r.body.indexOf('class="head-row"'),
        lessThan(r.body.indexOf('<form class="search"')),
      );
      expect(
        r.body.indexOf('<form class="search"'),
        lessThan(r.body.indexOf('class="grid"')),
      );
      // No User-Agent: the PC shell (layout-pc class, no mobile top bar).
      expect(r.body, contains('class="layout-pc"'));
      expect(r.body, isNot(contains('class="m-top"')));
      // No dark banner, no three-button section navigation.
      expect(r.body, isNot(contains('class="banner"')));
      expect(r.body, isNot(contains('href="#downloaded"')));
      expect(r.body, isNot(contains('href="#library"')));
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
      expect(r.body, contains('href="/download/1"'));
      expect(r.body, contains('href="/read/1"'));
      expect(r.body, contains('href="/download/2"'));
      // PDF reads in the browser's own viewer via /book, not /read.
      expect(r.body, contains('href="/book/2"'));
      expect(r.body, isNot(contains('href="/read/2"')));
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
      // Item 3: an undownloaded library book gets a POST form, never a
      // GET endpoint with a side effect.
      expect(r.body, contains('method="post" action="/request-download/9"'));
      expect(r.body, contains('下载到手机'));
      expect(r.body, isNot(contains('href="/request-download/9"')));
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
      expect(shelf.body, contains('href="/download/1"'));
      expect(shelf.body, contains('href="/read/1"'));
      // The search page shows the term, a way home, and the search
      // box — prefilled — on the results heading row. No sidebar.
      expect(byTitle.body, contains('搜索“EPUB”'));
      expect(byTitle.body, contains('Back to home'));
      expect(byTitle.body, contains('value="EPUB"'));
      expect(byTitle.body, contains('class="head-row"'));
      expect(byTitle.body, isNot(contains('class="sidebar"')));
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
      final r = await get('/download/1');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
      expect(r.header('content-disposition'), contains('attachment'));
      expect(r.header('content-length'), '21');
      expect(r.header('accept-ranges'), 'bytes');
    });

    test('Range requests resume', () async {
      final r = await get('/download/1', headers: {'Range': 'bytes=5-9'});
      expect(r.status, 206);
      expect(r.body, 'BYTES');
      expect(r.header('content-range'), 'bytes 5-9/21');
      expect(r.header('content-length'), '5');
    });

    test('Range suffix and open-ended forms', () async {
      final suffix = await get('/download/1', headers: {'Range': 'bytes=-5'});
      expect(suffix.status, 206);
      expect(suffix.body, '56789');
      expect(suffix.header('content-range'), 'bytes 16-20/21');

      final open = await get('/download/1', headers: {'Range': 'bytes=20-'});
      expect(open.status, 206);
      expect(open.body, '9');
      expect(open.header('content-range'), 'bytes 20-20/21');
    });

    test('an unsatisfiable Range is a 416 with the length', () async {
      for (final range in ['bytes=99-100', 'bytes=21-']) {
        final r = await get('/download/1', headers: {'Range': range});
        expect(r.status, 416, reason: range);
        expect(r.header('content-range'), 'bytes */21');
        expect(r.body, isEmpty);
      }
    });

    test('validators and privacy headers accompany file responses', () async {
      final full = await get('/download/1');
      final etag = full.header('etag');
      expect(etag, isNotNull);
      expect(full.header('last-modified'), isNotNull);
      expect(full.header('cache-control'), 'private, no-store');
      expect(full.header('referrer-policy'), 'no-referrer');
      expect(full.header('x-content-type-options'), 'nosniff');

      final fresh = await get(
        '/download/1',
        headers: {'Range': 'bytes=0-3', 'If-Range': etag!},
      );
      expect(fresh.status, 206);
      expect(fresh.body, 'EPUB');

      final stale = await get(
        '/download/1',
        headers: {'Range': 'bytes=0-3', 'If-Range': '"stale"'},
      );
      expect(stale.status, 200);
      expect(stale.body, 'EPUB-BYTES-0123456789');
    });

    test('malformed and multipart ranges are ignored safely', () async {
      for (final range in ['bytes=abc', 'bytes=0-1,4-5']) {
        final r = await get('/download/1', headers: {'Range': range});
        expect(r.status, 200, reason: range);
        expect(r.body, 'EPUB-BYTES-0123456789');
      }
      final reversed = await get(
        '/download/1',
        headers: {'Range': 'bytes=5-2'},
      );
      expect(reversed.status, 416);
    });

    test(
      'HEAD returns the same headers as GET; Kotlin drops the body',
      () async {
        final getR = await get('/download/1');
        final headR = await get('/download/1', method: 'HEAD');
        expect(headR.status, 200);
        expect(headR.header('content-length'), getR.header('content-length'));
        // The descriptor still carries the file — it is Kotlin, not
        // Dart, that skips the body for HEAD.
        expect(headR.response.filePath, isNotNull);
        expect(headR.response.fileStart, 0);
        expect(headR.response.fileEnd, 20);
      },
    );

    test('unknown book ids and odd paths 404 without crashing', () async {
      // Paths are already percent-decoded here (Kotlin decodes before
      // Dart sees them), so '..' arrives as '..'.
      for (final path in [
        '/download/4',
        '/download/999999999',
        '/download/-1',
        '/download/abc',
        '/download/1/extra',
        '/download/../../etc/passwd',
        '/download/../a.epub',
        '/download/${tmp.path}/a.epub',
        '/read/7',
        '/read/x',
        '/book/7',
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
      final r = await get('/read/1');
      expect(r.status, 200);
      expect(r.body, contains('/reader-assets/view.js'));
      expect(r.body, contains("const BOOK_URL = withToken('/book/1')"));
      expect(r.body, contains('const ACCESS_TOKEN = ""'));
      expect(r.body, contains("addEventListener('pageshow'"));
      expect(r.body, contains('!event.persisted || !suspended'));
    });

    test('PDF has no foliate read page, but /book serves it inline', () async {
      expect((await get('/read/2')).status, 404);
      final r = await get('/book/2');
      expect(r.status, 200);
      expect(r.body, 'PDF-BYTES');
      expect(r.header('content-type'), 'application/pdf');
      // No attachment: the browser's own PDF viewer opens it.
      expect(r.header('content-disposition'), isNull);
      expect(r.header('x-book-name'), 'book.pdf');
    });

    test('/book returns the raw bytes of an EPUB', () async {
      final r = await get('/book/1');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
      expect(r.header('x-book-name'), 'book.epub');
    });

    test('/book supports Range too', () async {
      final r = await get('/book/1', headers: {'Range': 'bytes=5-9'});
      expect(r.status, 206);
      expect(r.body, 'BYTES');
      expect(r.header('content-range'), 'bytes 5-9/21');
      expect(r.header('x-book-name'), 'book.epub');
    });

    test('TXT conversion is file-backed and supports Range', () async {
      File(
        '${tmp.path}/c.txt',
      ).writeAsStringSync('第一章 开始\n这是足够长的正文内容。\n\n第二章 继续\n更多内容。\n');
      final full = await get('/book/3');
      expect(full.status, 200);
      expect(full.header('content-type'), 'application/epub+zip');
      expect(full.response.body, isNull);
      expect(full.response.filePath, contains('${tmp.path}/cache'));
      expect(full.bytes.take(2), [0x50, 0x4b]);

      final part = await get(
        '/book/3',
        headers: {'Range': 'bytes=0-15', 'If-Range': full.header('etag')!},
      );
      expect(part.status, 206);
      expect(part.bytes, full.bytes.sublist(0, 16));
      expect(part.header('content-range'), startsWith('bytes 0-15/'));
    });

    test('an unconvertible TXT gives a readable page, not a crash', () async {
      final r = await get('/read/3');
      expect(r.status, 422);
      expect(r.body, contains('<html'));
      expect((await get('/')).status, 200);
      // Its download link is unaffected.
      expect((await get('/download/3')).status, 200);
    });

    test('an unconvertible TXT is a plain 422 on /book', () async {
      final r = await get('/book/3');
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
      final empty = WebService(
        requireAccessToken: false,
        assetLoader: (_) async => null,
      );
      addTearDown(empty.stop);
      await empty.start(snapshot: snapshot, preferredPort: 0);
      final r = await empty.handleRequest(
        method: 'GET',
        path: '/reader-assets/view.js',
      );
      expect(r.status, 404);
    });
  });

  group('access control and task API', () {
    test('a per-start token protects every route and all page links', () async {
      final svc = WebService(
        assetLoader: (path) async => utf8.encode('// $path'),
      );
      addTearDown(svc.stop);
      await svc.start(snapshot: snapshot, preferredPort: 0);
      final token = svc.accessToken!;
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));

      Future<WebResponse> request(
        String path, {
        String method = 'GET',
        Map<String, String> query = const {},
        Map<String, String> headers = const {},
        String? body,
      }) => svc.handleRequest(
        path: path,
        method: method,
        query: query,
        headers: headers,
        body: body,
      );

      expect((await request('/')).status, 401);
      expect((await request('/download/1')).status, 401);
      expect((await request('/', query: {'t': 'wrong'})).status, 401);
      final home = Reply(await request('/', query: {'t': token}));
      expect(home.status, 200);
      expect(home.body, contains('href="/download/1?t=$token"'));
      expect(home.body, contains('href="/read/1?t=$token"'));
      expect(home.body, contains('href="/book/2?t=$token"'));
      expect(home.body, contains('action="/request-download/9?t=$token"'));
      expect(home.body, contains('action="/search?t=$token"'));
      expect(home.body, contains('href="/zip/all?t=$token"'));
      expect(home.body, contains('href="/icon.png?t=$token"'));
      expect(home.header('cache-control'), 'private, no-store');
      expect(home.header('referrer-policy'), 'no-referrer');
      expect(
        (await request(
          '/book/1',
          headers: {'Authorization': 'Bearer $token'},
        )).status,
        200,
      );
      final reader = Reply(await request('/read/1', query: {'t': token}));
      expect(reader.body, contains("const BOOK_URL = withToken('/book/1')"));
      expect(reader.body, contains('const ACCESS_TOKEN = "$token"'));
      expect(reader.body, contains('/reader-assets/view.js?t=$token'));

      await svc.stop();
      await svc.start(snapshot: snapshot, preferredPort: 0);
      expect(svc.accessToken, isNot(token));
      expect((await request('/', query: {'t': token})).status, 401);
    });

    test('cross-origin POST is refused before invoking a handler', () async {
      var calls = 0;
      final svc = WebService(requireAccessToken: false);
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        onRequestDownload: (_) async {
          calls++;
          return WebDownloadRequest.started;
        },
      );
      const body = '{"bookId":9}';
      final crossOrigin = await svc.handleRequest(
        method: 'POST',
        path: '/api/download',
        body: body,
        headers: {'Host': '127.0.0.1:8080', 'Origin': 'https://evil.example'},
      );
      expect(crossOrigin.status, 403);
      expect(calls, 0);
      final sameOrigin = await svc.handleRequest(
        method: 'POST',
        path: '/api/download',
        body: body,
        headers: {'Host': '127.0.0.1:8080', 'Origin': 'http://127.0.0.1:8080'},
      );
      expect(sameOrigin.status, 202);
      expect(calls, 1);
    });

    test(
      'concurrent clicks create one task and status omits secrets',
      () async {
        var calls = 0;
        final gate = Completer<void>();
        var tasks = <DownloadTask>[];
        const book = Book(
          id: 9,
          title: 'Nine',
          extension: 'epub',
          hash: 'hash',
        );
        final svc = WebService(requireAccessToken: false);
        addTearDown(svc.stop);
        await svc.start(
          snapshot: snapshot,
          preferredPort: 0,
          tasksProvider: () => tasks,
          onRequestDownload: (_) async {
            calls++;
            await gate.future;
            tasks = [
              const DownloadTask(
                id: '9',
                book: book,
                status: DownloadStatus.pending,
              ),
            ];
            return WebDownloadRequest.started;
          },
          onTaskAction: (id, action) async {
            if (action == WebTaskAction.cancel) {
              tasks = [
                const DownloadTask(
                  id: '9',
                  book: book,
                  status: DownloadStatus.cancelled,
                ),
              ];
            } else {
              tasks = [
                DownloadTask(
                  id: '9',
                  book: book,
                  status: DownloadStatus.error,
                  receivedBytes: 12,
                  fileSize: 34,
                  error: '/private/path?cookie=secret',
                ),
              ];
            }
            return true;
          },
        );
        Future<WebResponse> post(String path, {String? body}) =>
            svc.handleRequest(method: 'POST', path: path, body: body);
        final first = post('/api/download', body: '{"bookId":9}');
        final second = post('/api/download', body: '{"bookId":9}');
        gate.complete();
        expect((await first).status, 202);
        expect((await second).status, 202);
        expect(calls, 1);

        final duplicate = Reply(
          await post('/api/download', body: '{"bookId":9}'),
        );
        expect(duplicate.status, 200);
        expect(calls, 1);
        expect(jsonDecode(duplicate.body)['message'], 'already downloading');
        final queued = Reply(
          await svc.handleRequest(method: 'GET', path: '/api/tasks/9'),
        );
        expect(jsonDecode(queued.body)['status'], 'queued');
        expect(
          (await svc.handleRequest(
            method: 'POST',
            path: '/api/tasks/1/cancel',
          )).status,
          403,
        );

        final failed = Reply(await post('/api/tasks/9/retry'));
        final failedJson = jsonDecode(failed.body) as Map<String, dynamic>;
        expect(failedJson['status'], 'failed');
        expect(failedJson['receivedBytes'], 12);
        expect(failedJson['totalBytes'], 34);
        expect(failedJson['retryable'], isTrue);
        expect(failed.body, isNot(contains('/private/path')));
        expect(failed.body, isNot(contains('secret')));
        final cancelled = Reply(await post('/api/tasks/9/cancel'));
        expect(jsonDecode(cancelled.body)['status'], 'cancelled');
        tasks = const [
          DownloadTask(
            id: '9',
            book: book,
            status: DownloadStatus.completed,
            progress: 1,
            fileSize: 150,
            receivedBytes: 100,
          ),
        ];
        final completed = Reply(
          await svc.handleRequest(method: 'GET', path: '/api/tasks/9'),
        );
        expect(jsonDecode(completed.body)['receivedBytes'], 150);
        expect(
          (await svc.handleRequest(
            method: 'GET',
            path: '/api/tasks/404',
          )).status,
          404,
        );
        for (final invalid in ['', '{}', '{"bookId":1.5}', '{"bookId":-1}']) {
          expect((await post('/api/download', body: invalid)).status, 400);
        }
      },
    );

    test('a replaced task id cannot inherit web ownership', () async {
      var tasks = <DownloadTask>[];
      const original = Book(id: 9, title: 'Nine', extension: 'epub');
      const replacement = Book(id: 10, title: 'Ten', extension: 'epub');
      final svc = WebService(requireAccessToken: false);
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        tasksProvider: () => tasks,
        onRequestDownload: (_) async {
          tasks = const [
            DownloadTask(
              id: '9',
              book: original,
              status: DownloadStatus.pending,
              generation: 1,
            ),
          ];
          return WebDownloadRequest.started;
        },
        onTaskAction: (_, _) async => true,
      );
      expect(
        (await svc.handleRequest(
          method: 'POST',
          path: '/api/download',
          body: '{"bookId":9}',
        )).status,
        202,
      );
      tasks = const [
        DownloadTask(
          id: '9',
          book: replacement,
          status: DownloadStatus.pending,
          generation: 1,
        ),
      ];
      expect(
        (await svc.handleRequest(
          method: 'POST',
          path: '/api/tasks/9/cancel',
        )).status,
        403,
      );
      expect(
        (await svc.handleRequest(method: 'GET', path: '/api/tasks/9')).status,
        404,
      );
    });

    test('a recreated same-book task cannot inherit web ownership', () async {
      var tasks = <DownloadTask>[];
      const book = Book(id: 9, title: 'Nine', extension: 'epub');
      final svc = WebService(requireAccessToken: false);
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        tasksProvider: () => tasks,
        onRequestDownload: (_) async {
          tasks = const [
            DownloadTask(
              id: '9',
              book: book,
              status: DownloadStatus.pending,
              generation: 1,
            ),
          ];
          return WebDownloadRequest.started;
        },
        onTaskAction: (_, _) async => true,
      );
      expect(
        (await svc.handleRequest(
          method: 'POST',
          path: '/api/download',
          body: '{"bookId":9}',
        )).status,
        202,
      );
      expect(
        (await svc.handleRequest(method: 'GET', path: '/api/tasks/9')).status,
        200,
      );
      tasks = const [
        DownloadTask(
          id: '9',
          book: book,
          status: DownloadStatus.pending,
          generation: 2,
        ),
      ];
      expect(
        (await svc.handleRequest(
          method: 'POST',
          path: '/api/tasks/9/cancel',
        )).status,
        403,
      );
      expect(
        (await svc.handleRequest(method: 'GET', path: '/api/tasks/9')).status,
        404,
      );
    });

    test('an in-flight ZIP keeps its request snapshot', () async {
      var current = snapshot;
      final started = Completer<void>();
      final release = Completer<void>();
      var resolutions = 0;
      final svc = WebService(
        requireAccessToken: false,
        pathResolver: (location) async {
          if (resolutions++ == 0) {
            started.complete();
            await release.future;
          }
          return location;
        },
      );
      addTearDown(svc.stop);
      await svc.start(
        snapshot: current,
        preferredPort: 0,
        snapshotProvider: () => current,
      );
      final pending = svc.handleRequest(method: 'POST', path: '/zip/all');
      await started.future;
      current = const WebSnapshot();
      expect(
        (await svc.handleRequest(method: 'GET', path: '/api/library')).status,
        200,
      );
      release.complete();
      final response = Reply(await pending);
      expect(response.status, 200);
      final archive = ZipDecoder().decodeBytes(response.bytes);
      expect(archive.files, hasLength(3));
    });

    test(
      'dynamic snapshots reorder files without changing book URLs',
      () async {
        var current = snapshot;
        await service.start(
          snapshot: current,
          preferredPort: 0,
          snapshotProvider: () => current,
        );
        final reordered = WebSnapshot(
          files: [snapshot.files[1], snapshot.files[0], snapshot.files[2]],
          library: const [],
        );
        current = reordered;
        expect((await get('/download/1')).body, 'EPUB-BYTES-0123456789');
        expect((await get('/download/2')).body, 'PDF-BYTES');

        current = WebSnapshot(
          files: const [],
          library: const [
            WebEntry(
              bookId: 42,
              title: 'New shelf book',
              author: '',
              extension: 'epub',
            ),
          ],
        );
        final library = await get('/api/library');
        final json = jsonDecode(library.body) as Map<String, dynamic>;
        expect((json['books'] as List).single['bookId'], 42);
        expect((json['books'] as List).single['downloadUrl'], isNull);
        expect((await get('/download/1')).status, 404);
      },
    );
  });

  group('zip, request-download, icon', () {
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

    test('zip GET confirms and POST streams a temporary stored ZIP', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final confirmation = await get('/zip/all');
      expect(confirmation.status, 200);
      expect(confirmation.header('content-type'), contains('text/html'));
      expect(confirmation.body, contains('确认打包'));
      expect(confirmation.response.filePath, isNull);

      final all = await get('/zip/all', method: 'POST');
      expect(all.status, 200);
      expect(all.header('content-type'), 'application/zip');
      expect(
        all.header('content-disposition'),
        contains('attachment; filename="downloaded-books.zip"'),
      );
      expect(all.response.body, isNull);
      expect(all.response.filePath, isNotNull);
      expect(all.response.deleteFileAfterSend, isTrue);
      // A zip stores file names in plain text (the entry name is
      // "Title - Author.ext", with unsafe characters replaced).
      expect(all.body, contains('Au.epub'));
      expect(all.body, contains('Pdf Book.pdf'));

      final archive = ZipDecoder().decodeBytes(all.bytes);
      expect(archive.files.map((file) => file.name), [
        'Epub _Book_ - Au.epub',
        'Pdf Book.pdf',
        'Blank Text.txt',
      ]);
      for (final file in archive.files) {
        expect(file.compression, CompressionType.none);
      }
      expect(
        utf8.decode(
          archive.files
                  .firstWhere((file) => file.name.endsWith('.epub'))
                  .content
              as List<int>,
        ),
        'EPUB-BYTES-0123456789',
      );
      expect(
        utf8.decode(
          archive.files.firstWhere((file) => file.name.endsWith('.pdf')).content
              as List<int>,
        ),
        'PDF-BYTES',
      );
      expect(
        utf8.decode(
          archive.files.firstWhere((file) => file.name.endsWith('.txt')).content
              as List<int>,
        ),
        '   \n  ',
      );
      expect((await get('/zip/other')).status, 404);
    });

    test('request-download calls the callback and confirms', () async {
      final calls = <int>[];
      final svc = WebService(
        requireAccessToken: false,
        assetLoader: (path) async => utf8.encode('// $path'),
        txtConverter: TxtToEpub(
          cacheDir: () async => Directory('${tmp.path}/cache'),
        ),
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
        await svc.handleRequest(method: 'POST', path: '/request-download/9'),
      );
      expect(r.status, 202);
      expect(calls, [9]);
      expect(
        (await svc.handleRequest(
          method: 'GET',
          path: '/request-download/9',
        )).status,
        405,
      );
      expect(r.body, contains('已请求下载到运行 Zlibx 的手机'));
      expect(r.body, contains('账号额度'));
      expect(r.body, contains('/api/tasks/9'));
      expect(
        (await svc.handleRequest(
          method: 'POST',
          path: '/request-download/abc',
        )).status,
        404,
      );
    });

    test('request-download reports an already-downloading book', () async {
      final svc = WebService(
        requireAccessToken: false,
        assetLoader: (path) async => utf8.encode('// $path'),
        txtConverter: TxtToEpub(
          cacheDir: () async => Directory('${tmp.path}/cache'),
        ),
      );
      addTearDown(svc.stop);
      await svc.start(
        snapshot: snapshot,
        preferredPort: 0,
        onRequestDownload: (_) async => WebDownloadRequest.alreadyDownloading,
      );
      final r = Reply(
        await svc.handleRequest(method: 'POST', path: '/request-download/9'),
      );
      expect(r.status, 200);
      expect(r.body, contains('手机已有这个下载任务，无需重复创建'));
      expect(r.body, isNot(contains('已请求下载到运行 Zlibx 的手机')));
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

    group('pc and mobile layouts', () {
      setUp(() async {
        await service.start(snapshot: snapshot, preferredPort: 0);
      });

      // Desktop browsers (and no User-Agent at all) get the PC shell;
      // phones get the single-column shell. The body class is what
      // these tests assert on. Both shells share one arrangement: no
      // sidebar, poem on top, search on the downloads heading row.
      test('desktop UA gets the PC layout', () async {
        const desktopUa =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
        final r = await get('/', headers: {'User-Agent': desktopUa});
        expect(r.status, 200);
        expect(r.body, contains('class="layout-pc"'));
        expect(r.body, isNot(contains('class="sidebar"')));
        expect(r.body, isNot(contains('class="m-top"')));
      });

      test('mobile UA gets the single-column layout', () async {
        const androidUa =
            'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
        final r = await get('/', headers: {'User-Agent': androidUa});
        expect(r.status, 200);
        expect(r.body, contains('class="layout-mobile"'));
        expect(r.body, isNot(contains('class="m-top"')));
        expect(r.body, isNot(contains('class="sidebar"')));
        // Same cards, stacked; download/read links still there.
        expect(r.body, contains('href="/download/1"'));
        expect(r.body, contains('href="/read/1"'));
        expect(r.body.toLowerCase(), isNot(contains('<script')));
        // An iPad UA counts as mobile too.
        const ipadUa =
            'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
            'Mobile/15E148 Safari/604.1';
        final ipad = await get('/', headers: {'User-Agent': ipadUa});
        expect(ipad.body, contains('class="layout-mobile"'));
      });

      test('?layout= forces a layout either way', () async {
        const mobileUa =
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
            'Mobile/15E148 Safari/604.1';
        const desktopUa =
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
        final forcedPc = await get(
          '/',
          headers: {'User-Agent': mobileUa},
          query: {'layout': 'pc'},
        );
        expect(forcedPc.body, contains('class="layout-pc"'));
        final forcedMobile = await get(
          '/',
          headers: {'User-Agent': desktopUa},
          query: {'layout': 'mobile'},
        );
        expect(forcedMobile.body, contains('class="layout-mobile"'));
        // An illegal value falls back to the User-Agent.
        final illegal = await get(
          '/',
          headers: {'User-Agent': mobileUa},
          query: {'layout': 'tablet'},
        );
        expect(illegal.body, contains('class="layout-mobile"'));
      });

      test('search page follows the same layout', () async {
        const androidUa =
            'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
        final r = await get(
          '/search',
          query: {'q': 'book'},
          headers: {'User-Agent': androidUa},
        );
        expect(r.status, 200);
        expect(r.body, contains('class="layout-mobile"'));
        expect(r.body, isNot(contains('class="m-top"')));
        expect(r.body, contains('value="book"'));
        expect(r.body, contains('class="head-row"'));
      });

      test(
        'both layouts: no sidebar, poem on top, search on the downloads row',
        () async {
          const desktopUa =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
          const androidUa =
              'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
          for (final ua in [desktopUa, androidUa]) {
            final r = await get('/', headers: {'User-Agent': ua});
            expect(r.status, 200);
            expect(r.body, isNot(contains('class="sidebar"')));
            expect(r.body, isNot(contains('class="m-top"')));
            expect(r.body, isNot(contains('基本设定')));
            expect(r.body, isNot(contains('已连接')));
            expect(r.body, isNot(contains('github.com/minglaiyo/zlibx')));
            // Poem is the first thing in the main area, above the sections.
            expect(r.body, contains('class="poem"'));
            expect(
              r.body.indexOf('邂逅相遇，适我愿兮'),
              lessThan(r.body.indexOf('id="downloaded"')),
            );
            // Search box shares the downloads heading row, right end.
            expect(r.body, contains('class="head-row"'));
            expect(
              r.body.indexOf('class="head-row"'),
              lessThan(r.body.indexOf('<form class="search"')),
            );
            expect(
              r.body.indexOf('<form class="search"'),
              lessThan(r.body.indexOf('class="grid"')),
            );
          }
        },
      );
    });
  });

  group('description html stripping', () {
    test('stripHtml removes tags, decodes entities, collapses space', () {
      expect(stripHtml('<p>天生一个仙人洞，无限风光在险峰</p>'), '天生一个仙人洞，无限风光在险峰');
      expect(
        stripHtml('<p>&nbsp;("Raymond"校对)</p><p>第二段</p>'),
        '("Raymond"校对) 第二段',
      );
      expect(
        stripHtml('a &amp; b &lt;c&gt; &quot;q&quot; &#39;s&#39;'),
        'a & b <c> "q" \'s\'',
      );
      expect(stripHtml('&#123; &#x7B;'), '{ {');
      expect(stripHtml('a\n\n  b\tc'), 'a b c');
      expect(stripHtml('<p></p>'), '');
      expect(stripHtml('plain text'), 'plain text');
    });

    test('a card shows the cleaned description, not raw html', () async {
      final htmlSnap = WebSnapshot(
        files: [
          WebFile(
            bookId: 1,
            title: 'Mao',
            author: '毛泽东',
            extension: 'epub',
            description: '<p>天生一个仙人洞，无限风光在险峰</p>',
            location: '${tmp.path}/a.epub',
          ),
          WebFile(
            bookId: 2,
            title: 'Solitude',
            author: '加西亚 · 马尔克斯',
            extension: 'epub',
            description:
                '<p>&nbsp;("Raymond"校对、批判版)</p><p>《百年孤独》是魔幻现实主义文学的代表作</p>',
            location: '${tmp.path}/a.epub',
          ),
        ],
        library: const [],
      );
      await service.start(snapshot: htmlSnap, preferredPort: 0);
      final r = await get('/');
      expect(r.status, 200);
      // Tags are gone, entities decoded, the text itself kept.
      expect(r.body, contains('天生一个仙人洞，无限风光在险峰'));
      expect(r.body, contains('Raymond'));
      expect(r.body, contains('校对、批判版'));
      expect(r.body, contains('《百年孤独》是魔幻现实主义文学的代表作'));
      // No raw tags or entities leak into the card.
      expect(r.body, isNot(contains('&lt;p&gt;')));
      expect(r.body, isNot(contains('&lt;/p&gt;')));
      expect(r.body, isNot(contains('&nbsp;')));
    });
  });
}
