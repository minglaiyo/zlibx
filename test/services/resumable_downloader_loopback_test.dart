import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/resumable_downloader.dart';

/// Real-loopback tests for [ResumableDownloader]: a real dart:io
/// [HttpServer] on localhost and a real Dio (default adapter) — no
/// fake adapter, so Range / If-Range / Content-Range / Content-Length
/// behaviour is exercised end to end, including what the HTTP stack
/// does with a dropped connection or a gzip answer. The fake-adapter
/// tests in resumable_downloader_test.dart cover the same logic at
/// unit level; these pin the wire behaviour (O13).
///
/// The server honours Range / If-Range the way a real origin does,
/// with knobs to misbehave. `seen` records every request's headers so
/// a test can assert what the downloader actually sent.
///
/// NOTE: there is deliberately NO server-side "drop the connection
/// mid-body" knob. Three attempts to simulate one all failed in CI:
/// advertising a full Content-Length and closing early delivers zero
/// bytes (dart:io HttpClient discards a partial fixed-length body),
/// detachSocket() hangs the tests, and flush-before-close still
/// delivers zero bytes. So a partial left by an interrupted download
/// is built the same way the other tests build one (write the prefix
/// + .meta directly), and the interruption itself is driven by a real
/// CancelToken against a trickling server (see `trickle`).
class _LoopbackOrigin {
  _LoopbackOrigin(this.body);

  List<int> body;
  String? etag = '"v1"';
  String contentType = 'application/epub+zip';
  bool trickle = false; // send the body in 512-byte chunks, 200ms apart
  int? contentRangeStart; // lie about where a 206 body starts
  int? force416Total; // answer 416 with Content-Range: bytes */N
  bool gzipBody = false; // gzip the body unless the client asked identity
  final List<Map<String, String>> seen = [];

  late HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/f');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    try {
      seen.add({
        for (final name in ['range', 'if-range', 'accept-encoding'])
          if (req.headers.value(name) != null)
            name: req.headers.value(name)!,
      });
      final range = req.headers.value('range');
      final ifRange = req.headers.value('if-range');
      final res = req.response;
      res.headers.contentType = ContentType.parse(contentType);
      if (etag != null) res.headers.set(HttpHeaders.etagHeader, etag!);

      var status = HttpStatus.ok;
      var out = body;
      if (range != null && (ifRange == null || ifRange == etag)) {
        final start = int.parse(
          range.substring('bytes='.length).split('-').first,
        );
        if (force416Total != null || start >= body.length) {
          final total = force416Total ?? body.length;
          res
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set('content-range', 'bytes */$total');
          await res.close();
          return;
        }
        out = body.sublist(start);
        status = HttpStatus.partialContent;
        res.headers.set(
          'content-range',
          'bytes ${contentRangeStart ?? start}-${body.length - 1}/${body.length}',
        );
      }
      res.statusCode = status;

      // Gzip only when the client allows it: a client that asked for
      // `identity` gets the raw bytes (that is what the downloader
      // requests for file downloads — O13).
      final acceptEncoding = req.headers.value('accept-encoding') ?? '';
      final doGzip = gzipBody && !acceptEncoding.contains('identity');
      final payload = doGzip ? gzip.encode(out) : out;
      if (doGzip) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      res.contentLength = payload.length;
      if (trickle) {
        // Send the body slowly so a test can cancel mid-stream: on
        // localhost a full body arrives too fast to cancel reliably,
        // and a 20ms gap still let the client coalesce the chunks
        // (the download then completed before the cancel fired).
        const chunkSize = 512;
        for (var i = 0; i < payload.length; i += chunkSize) {
          final end = (i + chunkSize).clamp(0, payload.length);
          res.add(payload.sublist(i, end));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await res.close();
        return;
      }
      res.add(payload);
      await res.close();
    } catch (_) {
      // A dropped response can surface here on the server side
      // too; the client-side assertions are what the test checks.
    }
  }
}

void main() {
  late Directory dir;
  late String path;
  late String metaPath;
  final book = List<int>.generate(4096, (i) => (i * 7) % 251);

  late _LoopbackOrigin origin;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resumable-loopback');
    path = '${dir.path}/book.epub.part';
    metaPath = ResumableDownloader.metaPathFor(path);
    origin = _LoopbackOrigin(book);
    await origin.start();
  });

  tearDown(() async {
    await origin.stop();
    await dir.delete(recursive: true);
  });


  test('206 resume over real HTTP', () async {
    // A partial + validator left behind by an earlier (interrupted)
    // run — written directly, like the other tests do (a server-side
    // mid-body drop is not reliably observable, see the class doc).
    // The resume itself still goes over real HTTP.
    await File(path).writeAsBytes(book.sublist(0, 2048));
    await File(metaPath).writeAsString('"v1"');
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), book);
    expect(File(metaPath).existsSync(), isFalse);
    expect(origin.seen.last['if-range'], '"v1"');
    expect(origin.seen.last['range'], 'bytes=2048-');
  });

  test('200 fallback when the validator changed', () async {
    // Partial + stale validator: the server's ETag moved on.
    await File(path).writeAsBytes(book.sublist(0, 2048));
    await File(metaPath).writeAsString('"v1"');
    origin.etag = '"v2"';
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), book);
    expect(File(metaPath).existsSync(), isFalse);
    // One request: it carried the stale If-Range, the server answered
    // 200, and the downloader restarted from zero (a resume would have
    // appended to the stale 2048-byte prefix).
    expect(origin.seen.length, 1);
    expect(origin.seen.first['if-range'], '"v1"');
  });

  test('416 with N == start keeps the completed file', () async {
    // The whole book is already on disk (the process was killed after
    // the stream ended but before the .meta was removed).
    await File(path).writeAsBytes(book);
    await File(metaPath).writeAsString('"v1"');
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), book);
    expect(File(metaPath).existsSync(), isFalse);
    // No restart: exactly one request, a resume for the full size.
    expect(origin.seen.length, 1);
    expect(origin.seen.first['range'], 'bytes=4096-');
  });

  test('416 with N < start resets and restarts from zero', () async {
    // Partial LONGER than the server's file: stale prefix from a
    // replaced remote file.
    await File(path).writeAsBytes(List<int>.filled(100, 9));
    await File(metaPath).writeAsString('"v1"');
    origin
      ..body = List<int>.generate(50, (i) => i)
      ..force416Total = 50;
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), origin.body);
    expect(File(metaPath).existsSync(), isFalse);
    // First request asked to resume past the end; the restart asked
    // for the whole file.
    expect(origin.seen.length, 2);
    expect(origin.seen.first['range'], 'bytes=100-');
    expect(origin.seen.last.containsKey('range'), isFalse);
  });

  test('206 with a wrong Content-Range start restarts from zero', () async {
    // Partial + validator, as if an earlier run was interrupted.
    await File(path).writeAsBytes(book.sublist(0, 2048));
    await File(metaPath).writeAsString('"v1"');
    // Misbehaving proxy: answers 206 but says the body starts at byte 0.
    origin.contentRangeStart = 0;
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), book);
    // Lying 206 + clean restart.
    expect(origin.seen.length, 2);
    expect(origin.seen.first['range'], 'bytes=2048-');
    expect(origin.seen.last.containsKey('range'), isFalse);
  });

  test('dropped connection throws and keeps the partial file', () async {
    // Interrupt a real download mid-stream: trickle the body so it is
    // still in flight when the cancel fires (on localhost a full body
    // arrives too fast to cancel reliably). Cancelling exercises the
    // same code path as a dropped connection — the stream errors and
    // the partial must survive as a valid resume point. The exact
    // partial length is not pinned (chunks may coalesce); only that
    // it is a non-empty proper prefix of the book.
    origin.trickle = true;
    final cancel = CancelToken();
    await expectLater(
      ResumableDownloader.download(
        Dio(),
        origin.url.toString(),
        path,
        cancelToken: cancel,
        // Cancel on the first progress event: the download is
        // guaranteed to still be in flight (most chunks remain).
        onProgress: (received, total) {
          if (received > 0) cancel.cancel();
        },
      ),
      throwsA(isA<Exception>()),
    );
    final partial = await File(path).readAsBytes();
    expect(partial.length, greaterThan(0));
    expect(partial.length, lessThan(book.length));
    expect(partial, book.sublist(0, partial.length));
    origin.trickle = false;
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    expect(await File(path).readAsBytes(), book);
  });

  test('gzip answer: the downloader asks for identity and gets raw bytes',
      () async {
    origin.gzipBody = true;
    await ResumableDownloader.download(Dio(), origin.url.toString(), path);
    // The regression pin: a file download must request identity, so
    // Content-Length always matches the bytes received (O13). The
    // server only gzips when the client did not ask for it.
    expect(origin.seen.first['accept-encoding'], contains('identity'));
    expect(await File(path).readAsBytes(), book);
    expect(File(metaPath).existsSync(), isFalse);
  });
}
