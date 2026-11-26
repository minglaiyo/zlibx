import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/resumable_downloader.dart';

/// Serves one fixed "remote file" and honours Range / If-Range the way a
/// real origin does, with knobs to misbehave.
class _Origin implements HttpClientAdapter {
  _Origin(this.body);

  List<int> body;
  String? etag = '"v1"';
  String contentType = 'application/epub+zip';
  bool truncate = false; // advertise full length but send half
  int? contentRangeStart; // lie about where a 206 body starts
  bool omitContentRange = false; // answer a 206 with no Content-Range
  final List<Map<String, dynamic>> seen = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(Map<String, dynamic>.from(options.headers));
    final range = options.headers['Range'] as String?;
    final ifRange = options.headers['If-Range'] as String?;
    final h = <String, List<String>>{
      Headers.contentTypeHeader: [contentType],
      if (etag != null) HttpHeaders.etagHeader: [etag!],
    };
    int status = 200;
    List<int> out = body;
    if (range != null && (ifRange == null || ifRange == etag)) {
      final start = int.parse(range.substring(6).replaceAll('-', ''));
      if (start >= body.length) {
        return ResponseBody.fromBytes(const [], 416, headers: h);
      }
      out = body.sublist(start);
      status = 206;
      if (!omitContentRange) {
        h['content-range'] = [
          'bytes ${contentRangeStart ?? start}-${body.length - 1}/${body.length}',
        ];
      }
    }
    h[Headers.contentLengthHeader] = ['${out.length}'];
    final sent = truncate ? out.sublist(0, out.length ~/ 2) : out;
    return ResponseBody.fromBytes(sent, status, headers: h);
  }
}

void main() {
  late Directory dir;
  late String path;
  // Plan item 8: the fixture is an EPUB, so it must start with the EPUB
  // magic — the first-chunk check rejects anything else.
  final book = [
    0x50,
    0x4B,
    ...List<int>.generate(4094, (i) => (i * 7) % 251),
  ];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resumable');
    path = '${dir.path}/book.epub.part';
  });
  tearDown(() => dir.delete(recursive: true));

  Dio dioFor(_Origin o) => Dio()..httpClientAdapter = o;

  test('fresh download writes the file and removes the sidecar', () async {
    final o = _Origin(book);
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
    expect(File(ResumableDownloader.metaPathFor(path)).existsSync(), isFalse);
  });

  test('rejects an HTML page labelled text/html and writes nothing', () async {
    final o = _Origin(utf8.encode('<html>challenge</html>'))
      ..contentType = 'text/html; charset=utf-8';
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadContentException>()),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('rejects an HTML body that is mislabelled as octet-stream', () async {
    final o = _Origin(utf8.encode('  <!DOCTYPE html><title>Just a moment'))
      ..contentType = 'application/octet-stream';
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadContentException>()),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('truncated stream throws and keeps the partial file', () async {
    final o = _Origin(book)..truncate = true;
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadTruncatedException>()),
    );
    expect(File(path).lengthSync(), book.length ~/ 2);
  });

  test('resumes with Range + If-Range when the validator matches', () async {
    final o = _Origin(book)..truncate = true;
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadTruncatedException>()),
    );
    o.truncate = false;
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
    expect(o.seen.last['If-Range'], '"v1"');
    expect(o.seen.last['Range'], startsWith('bytes='));
  });

  test('restarts from zero when a 206 starts at a different offset', () async {
    final o = _Origin(book)..truncate = true;
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadTruncatedException>()),
    );
    // Misbehaving proxy: answers 206 but says the body starts at byte 0.
    o
      ..truncate = false
      ..contentRangeStart = 0;
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
  });

  test('restarts from zero when the remote file changed', () async {
    final o = _Origin(book)..truncate = true;
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadTruncatedException>()),
    );
    // Remote file replaced: new bytes, new ETag.
    o
      ..truncate = false
      ..body = [0x50, 0x4B, ...List<int>.generate(4094, (i) => (i * 3) % 241)]
      ..etag = '"v2"';
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), o.body);
  });

  // The perf rule (2026-11-15, shared with the Z-Library engine): a
  // missing validator no longer drops the resume offset — a mirror that
  // sends neither ETag nor Last-Modified has none to record, and wiping
  // the partial re-transferred the whole book on every pause / retry.
  test('resumes a partial whose validator was never recorded', () async {
    await File(path).writeAsBytes(book.sublist(0, 100));
    final o = _Origin(book);
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
    expect(o.seen.length, 1);
    expect(o.seen.first['Range'], 'bytes=100-');
    expect(o.seen.first.containsKey('If-Range'), isFalse);
  });

  test('an unproven 206 restarts instead of appending', () async {
    // No Content-Range and no If-Range: nothing says these bytes belong
    // at this offset, so stitching them onto the partial is not allowed.
    await File(path).writeAsBytes(book.sublist(0, 100));
    final o = _Origin(book)..omitContentRange = true;
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
    expect(o.seen.length, 2);
  });

  test('an If-Range the server accepted proves the offset', () async {
    final o = _Origin(book)..truncate = true;
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadTruncatedException>()),
    );
    o
      ..truncate = false
      ..omitContentRange = true;
    await ResumableDownloader.download(dioFor(o), 'https://x/f', path);
    expect(await File(path).readAsBytes(), book);
    expect(o.seen.length, 2, reason: 'the resume was kept, not restarted');
  });

  test('looksLikeHtml ignores BOM/whitespace and real binaries', () {
    expect(
      ResumableDownloader.looksLikeHtml(utf8.encode('\uFEFF \n<HTML>')),
      isTrue,
    );
    expect(ResumableDownloader.looksLikeHtml([0x50, 0x4B, 3, 4]), isFalse);
    expect(ResumableDownloader.looksLikeHtml(const []), isFalse);
  });

  // Plan item 8: the first chunk already proves the body is not the
  // format the file claims, so nothing is written.
  test('rejects a PDF served for an EPUB and writes nothing', () async {
    final o = _Origin(utf8.encode('%PDF-1.7 fake pdf body'));
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadMagicException>()),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('a resumed partial with a bad prefix is discarded', () async {
    await File(path).writeAsBytes(List.filled(100, 0x78));
    final o = _Origin(book);
    await expectLater(
      ResumableDownloader.download(dioFor(o), 'https://x/f', path),
      throwsA(isA<DownloadMagicException>()),
    );
    expect(File(path).existsSync(), isFalse);
    expect(
      File(ResumableDownloader.metaPathFor(path)).existsSync(),
      isFalse,
    );
  });

  test('an FB2 with a BOM passes the magic check', () async {
    final fb2 = [
      0xEF,
      0xBB,
      0xBF,
      ...'<?xml version="1.0"?><FictionBook>'.codeUnits,
    ];
    final fb2Path = '${dir.path}/book.fb2.part';
    final o = _Origin(fb2);
    await ResumableDownloader.download(dioFor(o), 'https://x/f', fb2Path);
    expect(await File(fb2Path).readAsBytes(), fb2);
  });
}
