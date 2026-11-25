// Web service: port selection, singleton, snapshot, routes, path safety,
// reader-asset whitelist. Uses a real loopback server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_task.dart';
import 'package:zlibx/services/txt_to_epub.dart';
import 'package:zlibx/services/web_service.dart';

class _Reply {
  final int status;
  final String body;
  final List<int> bytes;
  final HttpHeaders headers;
  _Reply(this.status, this.bytes, this.headers)
    : body = utf8.decode(bytes, allowMalformed: true);
}

Future<_Reply> get(int port, String path, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    headers?.forEach(req.headers.set);
    final res = await req.close();
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return _Reply(res.statusCode, bytes, res.headers);
  } finally {
    client.close(force: true);
  }
}

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  late Directory tmp;
  late WebService service;
  late WebSnapshot snapshot;

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
  });

  tearDown(() async {
    await service.stop();
    tmp.deleteSync(recursive: true);
  });

  group('lifecycle & port', () {
    test('the fixed port is 8080', () {
      expect(kWebServicePort, 8080);
    });

    test('shared is one instance', () {
      expect(identical(WebService.shared, WebService.shared), isTrue);
    });

    test('binds the preferred port when it is free', () async {
      final want = await freePort();
      final got = await service.start(snapshot: snapshot, preferredPort: want);
      expect(got, want);
      expect(service.port, want);
      expect(service.isRunning, isTrue);
    });

    test('falls back to another port only when the preferred is taken', () async {
      final blocker = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => blocker.close(force: true));
      final got = await service.start(
        snapshot: snapshot,
        preferredPort: blocker.port,
      );
      expect(got, isNot(blocker.port));
      expect(got, greaterThan(0));
      expect(service.port, got); // reported port == actual port
      expect((await get(got, '/')).status, 200);
    });

    test('keeps running until stop() and can restart on the same port', () async {
      final want = await freePort();
      await service.start(snapshot: snapshot, preferredPort: want);
      // Starting again while running is a no-op (same port).
      expect(await service.start(snapshot: snapshot, preferredPort: 1), want);
      expect((await get(want, '/')).status, 200);

      await service.stop();
      expect(service.isRunning, isFalse);
      expect(service.port, isNull);

      expect(await service.start(snapshot: snapshot, preferredPort: want), want);
      expect((await get(want, '/')).status, 200);
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
    late int port;
    setUp(() async {
      port = await service.start(snapshot: snapshot, preferredPort: await freePort());
    });

    test('three sections, links, escaping, and no JavaScript', () async {
      final r = await get(port, '/');
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
      final r = await get(port, '/download/0');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
      expect(
        r.headers.value('content-disposition'),
        contains('attachment'),
      );
    });

    test('Range requests resume', () async {
      final r = await get(port, '/download/0', headers: {'Range': 'bytes=5-9'});
      expect(r.status, 206);
      expect(r.body, 'BYTES');
      expect(r.headers.value('content-range'), 'bytes 5-9/21');
    });

    test('booklist page lists preview books and the official link', () async {
      final r = await get(port, '/booklist/42');
      expect(r.status, 200);
      expect(r.body, contains('In list'));
      expect(r.body, contains('href="/download/0"'));
      expect(r.body, contains('https://z-library.example/booklist/42/x'));
    });

    test('out-of-range indexes and odd paths 404 without crashing', () async {
      for (final path in [
        '/download/3',
        '/download/999999999',
        '/download/-1',
        '/download/abc',
        '/download/0/extra',
        '/download/%2e%2e%2f%2e%2e%2fetc%2fpasswd',
        '/download/..%2fa.epub',
        '/download/${Uri.encodeComponent('${tmp.path}/a.epub')}',
        '/read/7',
        '/read/x',
        '/book/7',
        '/booklist/nope',
        '/booklist/42/more',
        '/nothing',
      ]) {
        final r = await get(port, path);
        expect(r.status, 404, reason: path);
      }
      // The server is still alive afterwards.
      expect((await get(port, '/')).status, 200);
    });

    test('non-GET methods are refused', () async {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/'));
      final res = await req.close();
      await res.drain<void>();
      client.close(force: true);
      expect(res.statusCode, 405);
    });
  });

  group('reader routes', () {
    late int port;
    setUp(() async {
      port = await service.start(snapshot: snapshot, preferredPort: await freePort());
    });

    test('/read serves the reader page for a readable book', () async {
      final r = await get(port, '/read/0');
      expect(r.status, 200);
      expect(r.body, contains('/reader-assets/view.js'));
      expect(r.body, contains('"/book/0"'));
    });

    test('PDF has no read page', () async {
      expect((await get(port, '/read/1')).status, 404);
      expect((await get(port, '/book/1')).status, 404);
    });

    test('/book returns the raw bytes of an EPUB', () async {
      final r = await get(port, '/book/0');
      expect(r.status, 200);
      expect(r.body, 'EPUB-BYTES-0123456789');
    });

    test('an unconvertible TXT gives a readable page, not a crash', () async {
      final r = await get(port, '/read/2');
      expect(r.status, 422);
      expect(r.body, contains('<html'));
      expect((await get(port, '/')).status, 200);
      // Its download link is unaffected.
      expect((await get(port, '/download/2')).status, 200);
    });

    test('/reader-assets serves only the whitelist', () async {
      for (final name in kReaderAssetWhitelist) {
        final r = await get(port, '/reader-assets/$name');
        expect(r.status, 200, reason: name);
      }
      expect(kReaderAssetWhitelist.length, 13);
      for (final path in [
        '/reader-assets/pdf.js',
        '/reader-assets/search.js',
        '/reader-assets/vendor/pdfjs/pdf.js',
        '/reader-assets/reader.html',
        '/reader-assets/../pubspec.yaml',
        '/reader-assets/%2e%2e/pubspec.yaml',
        '/reader-assets/vendor/',
        '/reader-assets/',
        '/reader-assets',
      ]) {
        final r = await get(port, path);
        expect(r.status, 404, reason: path);
      }
    });

    test('a whitelisted but not-yet-vendored file is a clean 404', () async {
      final empty = WebService(assetLoader: (_) async => null);
      addTearDown(empty.stop);
      final p = await empty.start(snapshot: snapshot, preferredPort: await freePort());
      expect((await get(p, '/reader-assets/view.js')).status, 404);
    });
  });
}
