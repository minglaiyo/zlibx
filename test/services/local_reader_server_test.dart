// LocalReaderServer: the loopback server feeding one book to the
// in-app reader's WebView. Real HttpServer on 127.0.0.1:0, real
// HttpClient requests — the same shape as the web service's tests,
// but the asset loader is injected (no real bundle in tests) and
// the TXT converter uses a temp cache dir.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/local_reader_server.dart';
import 'package:zlibx/services/txt_to_epub.dart';

Future<(int, String, Map<String, String>)> _get(Uri base, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(base.resolve(path));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final headers = <String, String>{};
    resp.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });
    return (resp.statusCode, body, headers);
  } finally {
    client.close();
  }
}

Future<List<int>> _getBytes(Uri base, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(base.resolve(path));
    final resp = await req.close();
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close();
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('local_reader_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  LocalReaderServer serverFor(String filePath, {String? savedCfi}) =>
      LocalReaderServer(
        filePath: filePath,
        title: 'Test Book',
        bookKey: '42',
        savedCfi: savedCfi,
        txt: TxtToEpub(cacheDir: () async => tmp),
        assetLoader: (path) async => utf8.encode('// $path'),
      );

  test('serves the reader page at / with the book key and saved CFI', () async {
    final book = File('${tmp.path}/book.epub');
    await book.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);
    final server = serverFor(book.path, savedCfi: 'epubcfi(/6/2!)');
    final base = await server.start();
    try {
      final (status, body, headers) = await _get(base, '/');
      expect(status, 200);
      expect(headers['content-type'], contains('text/html'));
      expect(body, contains('/assets/view.js'));
      expect(body, contains('/book'));
      expect(body, contains('zlibxReaderProgress'));
      expect(body, contains('epubcfi(/6/2!)'));
      expect(body, contains('Test Book'));
    } finally {
      await server.stop();
    }
  });

  test('/book serves the EPUB bytes with the right content type', () async {
    final bytes = List<int>.generate(64, (i) => i);
    final book = File('${tmp.path}/book.epub');
    await book.writeAsBytes(bytes);
    final server = serverFor(book.path);
    final base = await server.start();
    try {
      final got = await _getBytes(base, '/book');
      expect(got, bytes);
      final (status, _, headers) = await _get(base, '/book');
      expect(status, 200);
      expect(headers['content-type'], contains('application/epub+zip'));
      expect(headers['x-book-name'], 'book.epub');
    } finally {
      await server.stop();
    }
  });

  test('/book converts TXT to EPUB and serves it', () async {
    final txt = File('${tmp.path}/notes.txt');
    await txt.writeAsString('第一章 开始\n\n这是正文内容。\n');
    final server = serverFor(txt.path);
    final base = await server.start();
    try {
      final (status, _, headers) = await _get(base, '/book');
      expect(status, 200);
      expect(headers['content-type'], contains('application/epub+zip'));
      expect(headers['x-book-name'], 'book.epub');
      final got = await _getBytes(base, '/book');
      // EPUB is a zip: starts with PK.
      expect(got.sublist(0, 2), [0x50, 0x4B]);
    } finally {
      await server.stop();
    }
  });

  test('/book 404s when the file is gone', () async {
    final server = serverFor('${tmp.path}/missing.epub');
    final base = await server.start();
    try {
      final (status, _, _) = await _get(base, '/book');
      expect(status, 404);
    } finally {
      await server.stop();
    }
  });

  test('/assets serves only the whitelist', () async {
    final book = File('${tmp.path}/book.epub');
    await book.writeAsBytes([0x50, 0x4B]);
    final server = serverFor(book.path);
    final base = await server.start();
    try {
      for (final name in ['view.js', 'epub.js', 'vendor/zip.js']) {
        final (status, body, _) = await _get(base, '/assets/$name');
        expect(status, 200, reason: name);
        expect(body, contains('assets/web-reader/$name'));
      }
      for (final name in [
        'pdf.js',
        'search.js',
        'vendor/pdfjs/pdf.js',
        '../pubspec.yaml',
        'vendor/',
      ]) {
        final (status, _, _) = await _get(base, '/assets/$name');
        expect(status, 404, reason: name);
      }
    } finally {
      await server.stop();
    }
  });

  test('unknown paths 404 and the server stops on dispose', () async {
    final book = File('${tmp.path}/book.epub');
    await book.writeAsBytes([0x50, 0x4B]);
    final server = serverFor(book.path);
    final base = await server.start();
    expect(server.isRunning, isTrue);
    final (status, _, _) = await _get(base, '/nope');
    expect(status, 404);
    await server.stop();
    expect(server.isRunning, isFalse);
  });
}
