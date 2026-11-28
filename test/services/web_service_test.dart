// Web service: port reporting, singleton, snapshot, routes, path safety,
// reader-asset whitelist. The HTTP transport is a plain Dart HttpServer
// again (the native LanWebServer rewrite was reverted — the socket was
// never the problem, the missing local-network permission was), so
// start/stop really bind a socket here; routing is tested through
// [WebService.handleRequest] directly, and the permission gate is
// tested against a fake `zlibx/local_network` channel.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  /// The generated payload ([WebResponse.bodyStream], i.e. the zip),
  /// collected by [drain].
  Uint8List? _streamed;

  /// Collect the streamed body, the way the socket would receive it.
  Future<void> drain() async {
    final stream = response.bodyStream;
    if (stream == null) return;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream()) {
      builder.add(chunk);
    }
    _streamed = builder.takeBytes();
  }

  int get status => response.status;

  Uint8List get bytes {
    if (_streamed != null) return _streamed!;
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
    final reply = Reply(response);
    await reply.drain();
    return reply;
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
      // Covers: the EPUB has one (with an inline onerror that swaps a
      // dead / hotlink-protected remote image for the same
      // first-letter tile), the PDF has none and shows the tile
      // directly ('Pdf Book' -> 'P').
      expect(
        r.body,
        contains('<img class="cover" src="https://covers.example/a.jpg"'),
      );
      expect(r.body, contains('src="https://covers.example/shelf.jpg"'));
      expect(r.body, contains('data-ph="E"'));
      expect(r.body, contains('data-ph="O"'));
      // The inline handler reaches the browser with plain single quotes
      // (a literal backslash-quote would be a JS syntax error).
      expect(r.body, contains("onerror=\"var p=document.createElement('div')"));
      expect(r.body, contains("this.replaceWith(p)\">"));
      expect(r.body, contains('class="cover-ph"'));
      expect(r.body, contains('>P</div>'));
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('href="/read/0"'));
      expect(r.body, contains('href="/download/1"'));
      // PDF reads in the browser's own viewer via /book, not /read.
      expect(r.body, contains('href="/book/1"'));
      expect(r.body, isNot(contains('href="/read/1"')));
      expect(r.body, contains('Epub &lt;Book&gt;')); // escaped
      // The heading row carries a reload link (an empty href reloads
      // the page), so a reader can pull a re-synced snapshot without
      // the browser's own menu entry.
      expect(r.body, contains('class="refresh" href="">Refresh</a>'));
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

    test('files carry a strong ETag and Last-Modified for resuming', () async {
      final r = await get('/download/0');
      final etag = r.header('etag');
      expect(etag, isNotNull);
      expect(etag, startsWith('"'));
      expect(r.header('last-modified'), isNotNull);
    });

    test('If-Range: a matching validator resumes, a stale one restarts', () async {
      final etag = (await get('/download/0')).header('etag')!;
      final last = (await get('/download/0')).header('last-modified')!;

      final etagHit = await get(
        '/download/0',
        headers: {'Range': 'bytes=5-9', 'If-Range': etag},
      );
      expect(etagHit.status, 206);
      expect(etagHit.body, 'BYTES');

      final dateHit = await get(
        '/download/0',
        headers: {'Range': 'bytes=5-9', 'If-Range': last},
      );
      expect(dateHit.status, 206);

      // The file was replaced since the first half was saved: send all
      // of it with 200 rather than splice two different files.
      for (final stale in ['"0-0"', 'W/$etag', 'Mon, 01 Jan 2001 00:00:00 GMT']) {
        final r = await get(
          '/download/0',
          headers: {'Range': 'bytes=5-9', 'If-Range': stale},
        );
        expect(r.status, 200, reason: stale);
        expect(r.body, 'EPUB-BYTES-0123456789', reason: stale);
        expect(r.header('content-range'), isNull, reason: stale);
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

    test('a TXT is served as a cached EPUB file, streamed and Range-able', () async {
      File('${tmp.path}/d.txt').writeAsStringSync('第一章 开始\n内容\n\n第二章 继续\n更多\n');
      final withTxt = WebSnapshot(
        files: [
          ...snapshot.files,
          WebFile(
            bookId: 4,
            title: 'Novel',
            author: '',
            extension: 'txt',
            location: '${tmp.path}/d.txt',
          ),
        ],
      );
      await service.stop();
      await service.start(snapshot: withTxt, preferredPort: 0);

      final whole = await get('/book/3');
      expect(whole.status, 200);
      expect(whole.header('content-type'), 'application/epub+zip');
      expect(whole.header('x-book-name'), 'book.epub');
      // A file on disk (the cache entry), not a byte buffer.
      expect(whole.response.filePath, isNotNull);
      expect(whole.response.body, isNull);
      expect(ZipDecoder().decodeBytes(whole.bytes).files, isNotEmpty);

      final part = await get('/book/3', headers: {'Range': 'bytes=0-3'});
      expect(part.status, 206);
      expect(part.bytes, [0x50, 0x4b, 0x03, 0x04]);
      expect(part.header('content-range'), startsWith('bytes 0-3/'));
    });

    test('the reader page loads big books by ranges, with a full fallback', () async {
      final page = (await get('/read/0')).body;
      expect(page, contains('window.__ZLIBX'));
      expect(page, contains('Range: '));
      expect(page, contains('RangeFile'));
      expect(page, contains('readWithProgress'));
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

    test('zip routes pack the files and attach them', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final all = await get('/zip/all');
      expect(all.status, 200);
      expect(all.header('content-type'), 'application/zip');
      expect(
        all.header('content-disposition'),
        contains('attachment; filename="downloaded-books.zip"'),
      );
      // Generated on the fly: a stream, never an in-memory body.
      expect(all.response.body, isNull);
      expect(all.response.bodyStream, isNotNull);
      expect(all.bytes, isNotEmpty);
      // The length is exact, so the browser can show real progress.
      expect(all.header('content-length'), '${all.bytes.length}');
      // A zip stores file names in plain text (the entry name is
      // "Title - Author.ext", with unsafe characters replaced).
      expect(all.body, contains('Au.epub'));
      expect(all.body, contains('Pdf Book.pdf'));
      expect(all.body, contains('Blank Text.txt'));
      expect((await get('/zip/other')).status, 404);
    });

    test('the zip is a valid archive with the exact file contents', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final all = await get('/zip/all');
      final archive = ZipDecoder().decodeBytes(all.bytes);
      final byName = {
        for (final f in archive.files) f.name: utf8.decode(f.content as List<int>),
      };
      expect(byName.keys, containsAll(<String>[
        'Epub _Book_ - Au.epub',
        'Pdf Book.pdf',
        'Blank Text.txt',
      ]));
      expect(byName['Epub _Book_ - Au.epub'], 'EPUB-BYTES-0123456789');
      expect(byName['Pdf Book.pdf'], 'PDF-BYTES');
    });

    test('HEAD on the zip reports the length without building it', () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final getR = await get('/zip/all');
      final headR = await get('/zip/all', method: 'HEAD');
      expect(headR.header('content-length'), getR.header('content-length'));
    });

    test('refresh swaps the served snapshot without stopping the server',
        () async {
      await service.start(snapshot: snapshot, preferredPort: 0);
      final before = await get('/');
      expect(before.body, contains('Epub &lt;Book&gt;'));
      expect(service.isRunning, isTrue);

      File('${tmp.path}/fresh.epub').writeAsStringSync('FRESH-EPUB-BYTES');
      final fresh = WebSnapshot(
        files: [
          WebFile(
            bookId: 7,
            title: 'Fresh Book',
            author: 'New Author',
            extension: 'epub',
            location: '${tmp.path}/fresh.epub',
          ),
        ],
      );
      service.refresh(snapshot: fresh, strings: WebPageStrings.english);

      // Same server, same port, new content: a browser reload sees it.
      expect(service.isRunning, isTrue);
      final after = await get('/');
      expect(after.body, contains('Fresh Book'));
      expect(after.body, isNot(contains('Epub &lt;Book&gt;')));
      // The fresh file is downloadable through its new index.
      final dl = await get('/download/0');
      expect(dl.status, 200);
      expect(dl.body, 'FRESH-EPUB-BYTES');

      // While stopped, refresh is a no-op (next start() takes over).
      await service.stop();
      expect(service.isRunning, isFalse);
      service.refresh(snapshot: fresh, strings: WebPageStrings.english);
      expect(service.isRunning, isFalse);
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
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('href="/read/0"'));
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
 headers: {'User-Agent': mobileUa}, query: {'layout': 'pc'},
      );
      expect(forcedPc.body, contains('class="layout-pc"'));
      final forcedMobile = await get(
        '/', headers: {'User-Agent': desktopUa}, query: {'layout': 'mobile'},
      );
      expect(forcedMobile.body, contains('class="layout-mobile"'));
      // An illegal value falls back to the User-Agent.
      final illegal = await get(
        '/', headers: {'User-Agent': mobileUa}, query: {'layout': 'tablet'},
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

    test('both layouts: no sidebar, poem on top, search on the downloads row',
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
    });
  });
  });

  group('description html stripping', () {
    test('stripHtml removes tags, decodes entities, collapses space', () {
      expect(
        stripHtml('<p>天生一个仙人洞，无限风光在险峰</p>'),
        '天生一个仙人洞，无限风光在险峰',
      );
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
