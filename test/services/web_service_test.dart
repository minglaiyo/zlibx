// Web service: port reporting, singleton, snapshot, routes, path safety,
// reader-asset whitelist. The HTTP transport is native now
// (LanWebServer.kt), so there is no socket here at all: routing is
// tested through [WebService.handleRequest] directly, and the
// start/stop lifecycle is tested against a fake `zlibx/web_server`
// channel that stands in for the native side.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_task.dart';
import 'package:zlibx/services/txt_to_epub.dart';
import 'package:zlibx/services/web_service.dart';

/// A [WebResponse] with the file bytes materialised, so the route
/// tests read exactly what Kotlin would send: the in-memory [body],
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

/// A port number for start() calls. Nothing actually binds in these
/// tests (the channel is mocked), so any free-looking number works.
const int testPort = 45678;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zlibx/web_server');

  late Directory tmp;
  late WebService service;
  late WebSnapshot snapshot;
  late List<MethodCall> channelCalls;

  /// The port the fake native side "binds". -1 = echo the requested
  /// port; any other value = the native side picked a different one.
  late int mockStartPort;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('web_service_test');
    File('${tmp.path}/a.epub').writeAsStringSync('EPUB-BYTES-0123456789');
    File('${tmp.path}/b.pdf').writeAsStringSync('PDF-BYTES');
    File('${tmp.path}/c.txt').writeAsStringSync('   \n  '); // un-convertible

    snapshot = WebSnapshot(
      files: [
        WebFile(
          title: 'Epub <Book>',
          author: 'Au',
          extension: 'epub',
          location: '${tmp.path}/a.epub',
        ),
        WebFile(
          title: 'Pdf Book',
          author: '',
          extension: 'pdf',
          location: '${tmp.path}/b.pdf',
        ),
        WebFile(
          title: 'Blank Text',
          author: '',
          extension: 'txt',
          location: '${tmp.path}/c.txt',
        ),
      ],
      library: const [
        WebEntry(title: 'On shelf', author: '', extension: 'epub', fileIndex: 0),
        WebEntry(title: 'Not here', author: '', extension: 'epub'),
      ],
      booklists: const [
        WebBooklist(
          id: '42',
          name: 'My list',
          url: 'https://z-library.example/booklist/42/x',
          count: 9,
          books: [
            WebEntry(title: 'In list', author: '', extension: 'epub', fileIndex: 0),
          ],
        ),
      ],
    );

    service = WebService(
      assetLoader: (path) async => utf8.encode('// $path'),
      txtConverter: TxtToEpub(cacheDir: () async => Directory('${tmp.path}/cache')),
    );

    channelCalls = <MethodCall>[];
    mockStartPort = -1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          channelCalls.add(call);
          switch (call.method) {
            case 'start':
              final want = (call.arguments as Map)['port'] as int;
              return mockStartPort >= 0 ? mockStartPort : want;
            case 'stop':
              return null;
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

  /// Route a request through the service under test, the way the
  /// native server does after percent-decoding the path. [path] is
  /// therefore already decoded here (e.g. '..', not '%2e%2e').
  Future<Reply> get(
    String path, {
    String method = 'GET',
    Map<String, String>? headers,
  }) async {
    final response = await service.handleRequest(
      method: method,
      path: path,
      headers: headers ?? const <String, String>{},
    );
    return Reply(response);
  }

  MethodCall startCall() =>
      channelCalls.singleWhere((c) => c.method == 'start');

  group('lifecycle & port', () {
    test('the fixed port is 1122', () {
      expect(kWebServicePort, 1122);
    });

    test('shared is one instance', () {
      expect(identical(WebService.shared, WebService.shared), isTrue);
    });

    test('start reports the port the native side bound', () async {
      final got = await service.start(snapshot: snapshot, preferredPort: testPort);
      expect(got, testPort);
      expect(service.port, testPort);
      expect(service.isRunning, isTrue);
      expect(startCall().arguments['port'], testPort);
      // No addresses: the native side falls back to its 0.0.0.0 socket.
      expect(startCall().arguments['addresses'], isEmpty);
    });

    test('start passes the bind addresses to native, as strings', () async {
      await service.start(
        snapshot: snapshot,
        preferredPort: testPort,
        bindAddresses: <InternetAddress>[
          InternetAddress.loopbackIPv4,
          InternetAddress('10.0.0.9'),
        ],
      );
      expect(
        startCall().arguments['addresses'],
        ['127.0.0.1', '10.0.0.9'],
      );
    });

    test('the native side may return a different port than requested', () async {
      // The native port-0 fallback: the requested port was taken, so
      // the bound port is what Dart must report.
      mockStartPort = 48123;
      final got = await service.start(snapshot: snapshot, preferredPort: 1122);
      expect(got, 48123);
      expect(service.port, 48123);
      expect(service.isRunning, isTrue);
    });

    test('keeps running until stop() and can restart on the same port', () async {
      await service.start(snapshot: snapshot, preferredPort: testPort);
      // Starting again while running is a no-op (same port, no second
      // native call).
      expect(await service.start(snapshot: snapshot, preferredPort: 1), testPort);
      expect(
        channelCalls.where((c) => c.method == 'start').length,
        1,
      );
      expect((await get('/')).status, 200);

      await service.stop();
      expect(service.isRunning, isFalse);
      expect(service.port, isNull);

      expect(
        await service.start(snapshot: snapshot, preferredPort: testPort),
        testPort,
      );
      expect((await get('/')).status, 200);
    });

    test('a failed native start leaves the service stopped', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            channelCalls.add(call);
            throw PlatformException(
              code: 'BIND_FAILED',
              message: 'Permission denied (bind failed)',
            );
          });
      await expectLater(
        service.start(snapshot: snapshot, preferredPort: testPort),
        throwsA(isA<PlatformException>()),
      );
      expect(service.isRunning, isFalse);
      expect(service.port, isNull);
    });
  });

  group('snapshot', () {
    test('counts, shelf linking and filtering of unfinished tasks', () {
      final done = DownloadTask(
        id: '1',
        book: const Book(id: 1, title: 'One', author: 'A', extension: 'epub'),
        status: DownloadStatus.completed,
        filePath: '/x/one.epub',
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
        book: const Book(id: 3, title: 'Three', extension: 'epub'),
        status: DownloadStatus.downloading,
        filePath: '/x/three.epub',
      );
      final snap = WebSnapshot.build(
        tasks: [done, missing, running],
        saved: const [
          Book(id: 1, title: 'One', extension: 'epub'),
          Book(id: 9, title: 'Nine', extension: 'epub'),
        ],
        booklists: const [
          Booklist(
            id: '7',
            name: 'L',
            url: 'https://z.example/booklist/7',
            count: 3,
            previewBooks: [Book(id: 1, title: 'One'), Book(id: 8, title: 'Eight')],
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
    });
  });

  group('home page and downloads', () {
    setUp(() async {
      await service.start(snapshot: snapshot, preferredPort: testPort);
    });

    test('three sections, links, escaping, and no JavaScript', () async {
      final r = await get('/');
      expect(r.status, 200);
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('href="/read/0"'));
      expect(r.body, contains('href="/download/1"'));
      expect(r.body, isNot(contains('href="/read/1"'))); // PDF: no read link
      expect(r.body, contains('href="/booklist/42"'));
      expect(r.body, contains('Epub &lt;Book&gt;')); // escaped
      expect(r.body.toLowerCase(), isNot(contains('<script')));
      expect(r.body, contains('(3)')); // downloaded section count
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
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('https://z-library.example/booklist/42/x'));
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
      await service.start(snapshot: snapshot, preferredPort: testPort);
    });

    test('/read serves the reader page for a readable book', () async {
      final r = await get('/read/0');
      expect(r.status, 200);
      expect(r.body, contains('/reader-assets/view.js'));
      expect(r.body, contains('"/book/0"'));
    });

    test('PDF has no read page', () async {
      expect((await get('/read/1')).status, 404);
      expect((await get('/book/1')).status, 404);
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
      await empty.start(snapshot: snapshot, preferredPort: testPort);
      final r = await empty.handleRequest(method: 'GET', path: '/reader-assets/view.js');
      expect(r.status, 404);
    });
  });
}
