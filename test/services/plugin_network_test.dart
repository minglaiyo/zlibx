import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Network-layer tests for the plugin (M4, review phase 2): the
// redirect follower, the download engine and the file-link endpoint.
// All served by a fake adapter — no network.
//
// The redirect tests pin the merged `_sendFollowing` (S4) behaviour:
// a GET 301 to the slugged URL re-sends the query and keeps the
// session Cookie on the same host; a 307 hop's set-cookie rides the
// follow-up; a cross-host hop learns nothing and drops the Cookie; a
// chain that never settles fails instead of looping; a redirect
// without a Location, or to a non-https URL, fails instead of
// following. The 301-then-307 chain pins the S4 latent fix: once a
// 301 has turned the request into a GET, a later 307 keeps it a GET
// (the old `_delete` / `_postText` recomputed the method from the
// status code alone and wrongly switched it back).
//
// The download tests pin the S2/S3 engine: a 200 whose body is an
// epub (`PK…`) is written; a 200 whose body is HTML (mislabelled
// Content-Type) or plain text (fails the file-header check) throws
// [DownloadHtmlException] and writes nothing; a resume sends
// `Range` + `If-Range` (the validator from the `.meta` sidecar) and
// appends on 206; a 206 whose Content-Range starts elsewhere
// restarts from zero; a 416 truncates and restarts.
//
// The file-link tests pin the S3 streaming endpoint: a JSON body
// yields the link; a JSON error yields the server message; a
// non-JSON 200 with a binary Content-Type is the file itself (the
// endpoint URL is the download URL); a non-JSON 200 with
// `text/html` fails instead of being treated as a file stream.

const _sessionUserId = '35899435';
const _sessionUserKey = 'sessionkey-abc123';
const _profilePath = '/eapi/user/profile';
const _bookId = '123';
const _bookHash = 'abcdef';
const _filePath = '/eapi/book/$_bookId/$_bookHash/file';
const _linkHost = 'cdn.example.org';
const _linkUrl = 'https://$_linkHost/book.epub';
const _deleteListId = 4095945;
const _deletePath = '/papi/booklist/$_deleteListId/delete';

// A minimal epub: `PK` + 10 payload bytes. The file-header check only
// looks at the first two bytes; the rest makes resume math readable.
final _epubBytes = Uint8List.fromList([
  0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
]);
// The first 6 bytes of the epub (the resume prefix in the 206 test).
final _epubPrefix = _epubBytes.sublist(0, 6);
// The remaining bytes (the 206 body in the resume test).
final _epubRest = _epubBytes.sublist(6);
final _htmlBytes = Uint8List.fromList(
  '<!doctype html><html><body>challenge</body></html>'.codeUnits,
);
// 100 bytes of plain text: long enough for the file-header check to
// prove it is not a book (a body shorter than 68 bytes cannot be
// checked for the MOBI marker and passes — the length check is the
// primary guard there, so the magic check only rejects content that
// is provably not a book).
final _textBytes = Uint8List.fromList(List.filled(100, 0x78));
// A minimal PDF: `%PDF` + payload bytes. The file-link test streams a
// binary body to a `.pdf` path, so the fixture must carry the PDF
// magic — the plan-8 first-chunk check rejects a body whose magic does
// not match its extension.
final _pdfBytes = Uint8List.fromList([
  ...'%PDF-1.7'.codeUnits,
  0x0A,
  0x25,
  0xE2,
  0xE3,
  0xCF,
  0xD3,
]);

/// 4 KB with a real zip header: big enough that reading a couple of
/// chunks and reading the whole thing are far apart (the lookup
/// perf test).
final _bigEpub = Uint8List.fromList(
  [..._epubBytes, ...List<int>.filled(4096 - _epubBytes.length, 0x20)],
);

/// Serves canned network answers so the calls run without a network.
/// Records every request's method, URI and headers.
class _FakeAdapter implements HttpClientAdapter {
  // File endpoint (`GET /eapi/book/{id}/{hash}/file`).
  Map<String, dynamic>? fileJson;
  int fileStatusCode = 200;
  String fileContentType = 'application/json';
  // When set, the file endpoint answers with these raw bytes instead
  // of JSON (a binary stream or an HTML page).
  Uint8List? fileRawBody;

  // Download link (`GET https://cdn.example.org/book.epub`).
  int linkStatusCode = 200;
  Uint8List linkBody = _epubBytes;
  String linkContentType = 'application/epub+zip';
  // When set, the first link request answers 416 (the partial file is
  // longer than the server's file); the retry answers 200.
  bool link416First = false;
  // When set, the link request answers 206 with this Content-Range
  // instead of the correct `bytes <start>-…`.
  String? linkWrongContentRange;

  /// Answer a 206 with no `Content-Range` header at all (a proxy that
  /// strips it): the resume offset then has no proof of its own.
  bool linkNoContentRange = false;
  // When set, the link request answers 206 (a resume) instead of 200.
  bool linkResume = false;
  // The ETag the link answers with (recorded into the `.meta` sidecar
  // on a fresh download).
  String? linkEtag = '"etag-1"';

  // Delete endpoint (`GET /papi/booklist/{id}/delete`): the redirect
  // chain under test.
  bool deleteRedirectFirst = false;
  bool deleteRedirectAlways = false;
  String? deleteWallCookie;
  bool deleteRedirectCrossHost = false;
  bool deleteRedirectNoLocation = false;
  bool deleteRedirectNonHttps = false;
  // When true, the first hop is a 301 to the same URL and the second
  // hop is a 307 to the same URL (the S4 latent-fix chain).
  bool delete301Then307 = false;

  final List<String> requestedMethods = [];
  final List<Uri> requestedUris = [];
  final List<Map<String, dynamic>> requestedHeaders = [];
  int fileCalls = 0;
  int linkCalls = 0;
  int deleteCalls = 0;
  // Bytes the file endpoint handed over, one entry per call.
  // A lookup that cancels its token stops after a chunk or two;
  // one that waits for a drain reads the whole body.
  final List<int> fileBytesDelivered = [];
  // File-endpoint responses the client aborted instead of reading.
  int fileAborts = 0;

  Map<String, dynamic> profilePayload = const {
    'success': 1,
    'user': {
      'id': _sessionUserId,
      'email': 'reader@example.com',
      'name': 'Reader',
      'remixUserkey': _sessionUserKey,
    },
  };
  // The status the profile endpoint answers with (the session-verdict
  // tests drive 401 / 429 / 503 through it).
  int profileStatusCode = 200;
  // When set, the profile answers with this body verbatim instead of
  // [profilePayload] — a wall page or any other non-JSON answer.
  String? profileRawBody;

  // Login endpoint (`POST /eapi/user/login`): the session-learning
  // tests (plan item 9) drive the JSON and the Set-Cookie headers
  // through these. Default: a successful login whose user object
  // carries no session key and no cookies — no source at all.
  Map<String, dynamic>? loginJson;
  List<String> loginSetCookie = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedMethods.add(options.method);
    requestedUris.add(options.uri);
    requestedHeaders.add(Map<String, dynamic>.from(options.headers));
    final uri = options.uri;
    if (uri.path == '/eapi/user/login') {
      final payload =
          loginJson ??
          const {
            'success': 1,
            'user': {
              'id': _sessionUserId,
              'email': 'reader@example.com',
              'name': 'Reader',
            },
          };
      return ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          if (loginSetCookie.isNotEmpty)
            HttpHeaders.setCookieHeader: loginSetCookie,
        },
      );
    }
    if (uri.path == _profilePath) {
      final raw = profileRawBody;
      if (raw != null) {
        return ResponseBody.fromString(
          raw,
          profileStatusCode,
          headers: {Headers.contentTypeHeader: ['text/html']},
        );
      }
      return _json(profilePayload, statusCode: profileStatusCode);
    }
    if (uri.path == _filePath) {
      fileCalls++;
      if (fileRawBody != null) {
        // Serve the body in 128-byte pieces, one per timer tick: dio
        // pipes an adapter stream eagerly (response_stream_handler
        // subscribes even for ResponseType.stream), so "cancelled"
        // only means "stopped early" — counting chunks is what makes
        // a drain observable.
        final idx = fileBytesDelivered.length;
        fileBytesDelivered.add(0);
        cancelFuture?.then((_) => fileAborts++).ignore();
        const chunkSize = 128;
        final chunks = <Uint8List>[];
        for (var at = 0; at < fileRawBody!.length; at += chunkSize) {
          final end = at + chunkSize < fileRawBody!.length
              ? at + chunkSize
              : fileRawBody!.length;
          chunks.add(Uint8List.sublistView(fileRawBody!, at, end));
        }
        return ResponseBody(
          Stream<Uint8List>.fromIterable(chunks).asyncMap((chunk) async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            fileBytesDelivered[idx] += chunk.length;
            return chunk;
          }),
          fileStatusCode,
          headers: {Headers.contentTypeHeader: [fileContentType]},
        );
      }
      final payload =
          fileJson ?? {'success': 1, 'downloadLink': _linkUrl};
      return ResponseBody.fromString(
        jsonEncode(payload),
        fileStatusCode,
        headers: {Headers.contentTypeHeader: [fileContentType]},
      );
    }
    if (uri.host == _linkHost) {
      linkCalls++;
      final range = options.headers['Range'] as String?;
      if (link416First && linkCalls == 1) {
        return ResponseBody.fromString(
          '',
          416,
          headers: {Headers.contentTypeHeader: ['application/epub+zip']},
        );
      }
      // A 206 is only ever the answer to a resume attempt (a request
      // carrying Range). A fresh request — including the retry after a
      // 416 or a wrong Content-Range — is answered 200 with the full
      // body, the way a real server behaves.
      if (range != null && (linkResume || linkWrongContentRange != null)) {
        final start = _epubPrefix.length;
        return ResponseBody.fromBytes(
          _epubRest,
          206,
          headers: {
            Headers.contentTypeHeader: [linkContentType],
            HttpHeaders.contentLengthHeader: ['${_epubRest.length}'],
            if (!linkNoContentRange)
              HttpHeaders.contentRangeHeader: [
                linkWrongContentRange ??
                    'bytes $start-${_epubBytes.length - 1}/${_epubBytes.length}',
              ],
            if (linkEtag != null) HttpHeaders.etagHeader: [linkEtag!],
          },
        );
      }
      return ResponseBody.fromBytes(
        linkBody,
        linkStatusCode,
        headers: {
          Headers.contentTypeHeader: [linkContentType],
          HttpHeaders.contentLengthHeader: ['${linkBody.length}'],
          if (linkEtag != null) HttpHeaders.etagHeader: [linkEtag!],
        },
      );
    }
    if (uri.path == _deletePath) {
      deleteCalls++;
      if (delete301Then307) {
        if (deleteCalls == 1) {
          return ResponseBody.fromString(
            '',
            301,
            headers: {HttpHeaders.locationHeader: [uri.toString()]},
          );
        }
        if (deleteCalls == 2) {
          return ResponseBody.fromString(
            '',
            307,
            headers: {HttpHeaders.locationHeader: [uri.toString()]},
          );
        }
        return _json(const {'success': 1});
      }
      if (deleteRedirectAlways || (deleteRedirectFirst && deleteCalls == 1)) {
        final wallCookie = deleteWallCookie;
        final headers = <String, List<String>>{
          HttpHeaders.locationHeader: [
            deleteRedirectCrossHost
                ? 'https://static.example.org$_deletePath'
                : deleteRedirectNonHttps
                    ? 'http://bookroom.lifestyle$_deletePath'
                    : uri.toString(),
          ],
          if (wallCookie != null)
            HttpHeaders.setCookieHeader: ['__diamwall=$wallCookie'],
        };
        if (deleteRedirectNoLocation) {
          headers.remove(HttpHeaders.locationHeader);
        }
        return ResponseBody.fromString('', 307, headers: headers);
      }
      return _json(const {'success': 1});
    }
    return _json({'success': 0, 'error': 'not found'}, statusCode: 404);
  }

  ResponseBody _json(Map<String, dynamic> payload, {int statusCode = 200}) {
    return ResponseBody.fromString(
      jsonEncode(payload),
      statusCode,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  return ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
}

Future<ZLibraryApi> _loggedInApi(_FakeAdapter adapter) async {
  final api = _apiWith(adapter);
  final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
  expect(login.success, isTrue);
  return api;
}

/// Indexes (into the recorded requests) of every call to [path], in
/// order — the redirect tests pick hops out of the recording, which
/// also holds the profile request that loginWithToken makes.
List<int> _hopIndexes(List<Uri> uris, String path) => [
      for (var i = 0; i < uris.length; i++)
        if (uris[i].path == path) i,
    ];

void main() {
  group('redirect follower (S4)', () {
    test('GET 307 to the same URL re-sends the request and succeeds',
        () async {
      final adapter = _FakeAdapter()..deleteRedirectFirst = true;
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isTrue);
      expect(adapter.deleteCalls, 2);
      // loginWithToken's profile GET plus the two delete hops.
      expect(adapter.requestedMethods.where((m) => m == 'GET').length, 3);
    });

    test('307 hop set-cookie rides the follow-up request', () async {
      final adapter = _FakeAdapter()
        ..deleteRedirectFirst = true
        ..deleteWallCookie = 'ddg-token=';
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isTrue);
      expect(adapter.deleteCalls, 2);
      final hops = _hopIndexes(adapter.requestedUris, _deletePath);
      expect(hops.length, 2);
      final firstHop = adapter.requestedHeaders[hops[0]];
      expect(firstHop['Cookie'], contains('remix_userid=$_sessionUserId'));
      expect(firstHop['Cookie'], isNot(contains('__diamwall')));
      final secondHop = adapter.requestedHeaders[hops[1]];
      expect(secondHop['Cookie'], contains('__diamwall=ddg-token='));
      expect(secondHop['Cookie'], contains('remix_userid=$_sessionUserId'));
    });

    test('cross-host redirect learns nothing and drops the Cookie',
        () async {
      final adapter = _FakeAdapter()
        ..deleteRedirectFirst = true
        ..deleteRedirectCrossHost = true
        ..deleteWallCookie = 'ddg-token=';
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      // The cross-host hop is followed (the fake answers 200 there),
      // but the session Cookie must not travel to the other host and
      // the other host's set-cookie must not enter the jar.
      expect(response.success, isTrue);
      expect(adapter.deleteCalls, 2);
      final hops = _hopIndexes(adapter.requestedUris, _deletePath);
      expect(hops.length, 2);
      final secondHop = adapter.requestedHeaders[hops[1]];
      expect(secondHop['Cookie'], isNull);
    });

    test('redirect that keeps redirecting fails instead of looping',
        () async {
      final adapter = _FakeAdapter()..deleteRedirectAlways = true;
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isFalse);
      expect(response.error, contains('too many redirects'));
      expect(adapter.deleteCalls, 5);
    });

    test('redirect without a Location fails instead of following',
        () async {
      final adapter = _FakeAdapter()
        ..deleteRedirectFirst = true
        ..deleteRedirectNoLocation = true;
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isFalse);
      expect(response.error, contains('redirect without location'));
      expect(adapter.deleteCalls, 1);
    });

    test('redirect to a non-https URL fails instead of following',
        () async {
      final adapter = _FakeAdapter()
        ..deleteRedirectFirst = true
        ..deleteRedirectNonHttps = true;
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isFalse);
      expect(response.error, contains('redirect to non-https URL'));
      expect(adapter.deleteCalls, 1);
    });

    test('301-then-307 chain keeps the request a GET', () async {
      // The S4 latent fix: a 301 turns the request into a GET, and a
      // later 307 must keep it a GET — not switch it back to the
      // original method. deleteBooklist is a GET throughout, so the
      // chain is GET -> 301 -> GET -> 307 -> GET -> 200; the
      // assertion is that all three hops are GET (the old code
      // recomputed the method from the status alone, which for a
      // DELETE/POST caller would have switched back).
      final adapter = _FakeAdapter()..delete301Then307 = true;
      final api = await _loggedInApi(adapter);

      final response = await api.deleteBooklist(_deleteListId);

      expect(response.success, isTrue);
      expect(adapter.deleteCalls, 3);
      final hops = _hopIndexes(adapter.requestedUris, _deletePath);
      expect(hops.length, 3);
      for (final hop in hops) {
        expect(adapter.requestedMethods[hop], 'GET');
      }
    });
  });

  group('download engine (S2/S3)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('zlibx_dl_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    String savePath(String name) => '${tempDir.path}/$name';

    test('200 with an epub body writes the file', () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).readAsBytes(), _epubBytes);
      expect(adapter.fileCalls, 1);
      expect(adapter.linkCalls, 1);
    });

    test('200 with an HTML body throws and writes nothing', () async {
      final adapter = _FakeAdapter()
        ..linkBody = _htmlBytes
        ..linkContentType = 'text/html';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');

      await expectLater(
        api.downloadBook(_bookId, _bookHash, path),
        throwsA(isA<DownloadHtmlException>()),
      );
      expect(await File(path).exists(), isFalse);
    });

    test('200 with a non-book body throws a magic mismatch and writes nothing',
        () async {
      final adapter = _FakeAdapter()
        ..linkBody = _textBytes
        ..linkContentType = 'application/octet-stream';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');

      // Plan item 8: the first chunk already proves the body is not an
      // EPUB, so nothing is written and the error names the mismatch —
      // the old finish-line DownloadHtmlException (with the partial
      // kept) no longer applies to this case.
      await expectLater(
        api.downloadBook(_bookId, _bookHash, path),
        throwsA(isA<DownloadMagicException>()),
      );
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.meta').exists(), isFalse);
    });

    test('resume sends Range + If-Range and appends on 206', () async {
      final adapter = _FakeAdapter()..linkResume = true;
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');
      await File(path).writeAsBytes(_epubPrefix);
      await File('$path.meta').writeAsString('"etag-1"');

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).readAsBytes(), _epubBytes);
      // The link request carried the resume headers.
      final linkHop = adapter.requestedUris.indexWhere(
        (u) => u.host == _linkHost,
      );
      final headers = adapter.requestedHeaders[linkHop];
      expect(headers['Range'], 'bytes=${_epubPrefix.length}-');
      expect(headers['If-Range'], '"etag-1"');
    });

    // The perf rule (2026-11-15): a missing validator is not permission
    // to re-download the book. The offset is proven by the answer instead.
    test('resume without a recorded validator keeps the bytes on disk',
        () async {
      final adapter = _FakeAdapter()..linkResume = true;
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');
      // A partial with no `.meta` sidecar: a mirror that sent neither
      // ETag nor Last-Modified (or a file left by a pre-1.6.0 build).
      await File(path).writeAsBytes(_epubPrefix);

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).readAsBytes(), _epubBytes);
      final linkHop = adapter.requestedUris.indexWhere(
        (u) => u.host == _linkHost,
      );
      final headers = adapter.requestedHeaders[linkHop];
      expect(headers['Range'], 'bytes=${_epubPrefix.length}-');
      expect(headers['If-Range'], isNull);
      // One link request: the resume never fell back to the full body.
      expect(adapter.linkCalls, 1);
    });

    test('a 206 without Content-Range is trusted only past an If-Range',
        () async {
      // (a) no validator recorded, no Content-Range proof: restart.
      final blind = _FakeAdapter()
        ..linkResume = true
        ..linkNoContentRange = true;
      final blindApi = await _loggedInApi(blind);
      final blindPath = savePath('blind.epub');
      await File(blindPath).writeAsBytes(_epubPrefix);

      await blindApi.downloadBook(_bookId, _bookHash, blindPath);

      expect(await File(blindPath).readAsBytes(), _epubBytes);
      expect(blind.linkCalls, 2, reason: 'the unproven 206 was discarded');

      // (b) same server, but If-Range was accepted: append, no restart.
      final proven = _FakeAdapter()
        ..linkResume = true
        ..linkNoContentRange = true;
      final provenApi = await _loggedInApi(proven);
      final provenPath = savePath('proven.epub');
      await File(provenPath).writeAsBytes(_epubPrefix);
      await File('$provenPath.meta').writeAsString('"etag-1"');

      await provenApi.downloadBook(_bookId, _bookHash, provenPath);

      expect(await File(provenPath).readAsBytes(), _epubBytes);
      expect(proven.linkCalls, 1);
    });

    test('a format with no fixed magic is not rejected at the finish line',
        () async {
      // The old positive check demanded PK / %PDF / BOOKMOBI, so a txt,
      // fb2 or djvu book was thrown away *after* the full transfer and
      // restarted from zero forever.
      final adapter = _FakeAdapter()
        ..linkBody = _textBytes
        ..linkContentType = 'application/octet-stream';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.txt');

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).readAsBytes(), _textBytes);
    });

    test('206 with a wrong Content-Range restarts from zero', () async {
      final adapter = _FakeAdapter()
        ..linkResume = true
        ..linkWrongContentRange = 'bytes 999-1004/1010';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');
      await File(path).writeAsBytes(_epubPrefix);
      await File('$path.meta').writeAsString('"etag-1"');

      await api.downloadBook(_bookId, _bookHash, path);

      // The 206 body (the epub tail) was discarded and the whole file
      // was re-fetched from zero, so the file is the full epub — not
      // the prefix plus the tail twice.
      expect(await File(path).readAsBytes(), _epubBytes);
      expect(adapter.linkCalls, 2);
    });

    test('416 truncates the partial file and restarts', () async {
      final adapter = _FakeAdapter()..link416First = true;
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');
      // Longer than the server's file: the first request is 416.
      await File(path).writeAsBytes(
        Uint8List.fromList([..._epubBytes, 0x09, 0x0A, 0x0B]),
      );
      await File('$path.meta').writeAsString('"etag-1"');

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).readAsBytes(), _epubBytes);
      expect(adapter.linkCalls, 2);
    });

    // Plan item 8: the production save path ends in `.part`, and the
    // old extension rule read the extension off that suffix — the
    // finish-line check silently never ran. These tests save through a
    // `.part` path, the way the engine does.
    test('a .part path still checks the real extension', () async {
      final adapter = _FakeAdapter()
        ..linkBody = _textBytes
        ..linkContentType = 'application/octet-stream';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub.part');

      await expectLater(
        api.downloadBook(_bookId, _bookHash, path),
        throwsA(isA<DownloadMagicException>()),
      );
      expect(await File(path).exists(), isFalse);
    });

    test('a PDF served for an EPUB throws a magic mismatch', () async {
      final adapter = _FakeAdapter()
        ..linkBody = Uint8List.fromList('%PDF-1.7 fake pdf body'.codeUnits)
        ..linkContentType = 'application/pdf';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub');

      await expectLater(
        api.downloadBook(_bookId, _bookHash, path),
        throwsA(isA<DownloadMagicException>()),
      );
      expect(await File(path).exists(), isFalse);
    });

    test('a resumed partial with a bad prefix is discarded', () async {
      final adapter = _FakeAdapter()..linkResume = true;
      final api = await _loggedInApi(adapter);
      final path = savePath('book.epub.part');
      await File(path).writeAsBytes(_textBytes.sublist(0, 100));
      await File('$path.meta').writeAsString('"etag-1"');

      await expectLater(
        api.downloadBook(_bookId, _bookHash, path),
        throwsA(isA<DownloadMagicException>()),
      );
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.meta').exists(), isFalse);
    });

    test('an FB2 with a BOM passes the magic check', () async {
      final adapter = _FakeAdapter()
        ..linkBody = Uint8List.fromList([
          0xEF,
          0xBB,
          0xBF,
          ...'<?xml version="1.0"?><FictionBook>'.codeUnits,
        ])
        ..linkContentType = 'application/xml';
      final api = await _loggedInApi(adapter);
      final path = savePath('book.fb2');

      await api.downloadBook(_bookId, _bookHash, path);

      expect(await File(path).exists(), isTrue);
    });
  });

  // Plan item 9: the login session comes from three sources, in
  // priority order — the user object (JSON), Set-Cookie, root fields —
  // with the `remix_user_key` alias accepted everywhere. A source that
  // is missing simply does not contribute.
  group('login learns the session from Set-Cookie / root fields', () {
    test('Set-Cookie fills the session when the JSON has no key', () async {
      final adapter = _FakeAdapter()
        ..loginSetCookie = [
          'remix_userid=$_sessionUserId; Path=/',
          'remix_userkey=$_sessionUserKey; Path=/; HttpOnly',
        ];
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.success, isTrue);
      expect(result.data?.remixUserkey, _sessionUserKey);
      // The next request carries the learned pair.
      await api.getProfile();
      final cookie =
          adapter.requestedHeaders.last['Cookie'] as String?;
      expect(cookie, contains('remix_userid=$_sessionUserId'));
      expect(cookie, contains('remix_userkey=$_sessionUserKey'));
    });

    test('the remix_user_key alias works in Set-Cookie', () async {
      final adapter = _FakeAdapter()
        ..loginSetCookie = ['remix_user_key=$_sessionUserKey; Path=/'];
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.success, isTrue);
      expect(result.data?.remixUserkey, _sessionUserKey);
    });

    test('root fields fill the session when there is no Set-Cookie',
        () async {
      final adapter = _FakeAdapter()
        ..loginJson = {
          'success': 1,
          'remix_userid': _sessionUserId,
          'remix_userkey': _sessionUserKey,
          'user': {
            'id': _sessionUserId,
            'email': 'reader@example.com',
            'name': 'Reader',
          },
        };
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.success, isTrue);
      expect(result.data?.remixUserkey, _sessionUserKey);
    });

    test('the root remix_user_key alias works', () async {
      final adapter = _FakeAdapter()
        ..loginJson = {
          'success': 1,
          'remix_userid': _sessionUserId,
          'remix_user_key': _sessionUserKey,
          'user': {
            'id': _sessionUserId,
            'email': 'reader@example.com',
            'name': 'Reader',
          },
        };
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.success, isTrue);
      expect(result.data?.remixUserkey, _sessionUserKey);
    });

    test('priority is user object, then Cookie, then root fields', () async {
      final adapter = _FakeAdapter()
        ..loginJson = {
          'success': 1,
          'remix_userid': _sessionUserId,
          'remix_userkey': 'root-key',
          'user': {
            'id': _sessionUserId,
            'email': 'reader@example.com',
            'name': 'Reader',
            'remixUserkey': 'json-key',
          },
        }
        ..loginSetCookie = ['remix_userkey=cookie-key; Path=/'];
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.data?.remixUserkey, 'json-key');

      // Without the user-object key, the Cookie beats the root field.
      final adapter2 = _FakeAdapter()
        ..loginJson = {
          'success': 1,
          'remix_userid': _sessionUserId,
          'remix_userkey': 'root-key',
          'user': {
            'id': _sessionUserId,
            'email': 'reader@example.com',
            'name': 'Reader',
          },
        }
        ..loginSetCookie = ['remix_userkey=cookie-key; Path=/'];
      final api2 = _apiWith(adapter2);

      final result2 = await api2.login('reader@example.com', 'pw');

      expect(result2.data?.remixUserkey, 'cookie-key');
    });

    test('no source leaves the session empty (existing flow)', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final result = await api.login('reader@example.com', 'pw');

      expect(result.success, isTrue);
      expect(result.data?.remixUserkey, isEmpty);
    });
  });

  // Which answers may blame the stored credentials — the verdict the app
  // needs before it dares to delete anything (module 2).
  group('session-rejection verdicts', () {
    test('a bare 401 blames the session', () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      adapter.profileStatusCode = 401;
      final res = await api.getProfile();

      expect(res.success, isFalse);
      expect(res.authRejected, isTrue);
      expect(notices, 1);
    });

    test('an HTTP 200 whose payload rejects the key blames the session too',
        () async {
      // eapi answers a dead session as `success: 0` with the reason in the
      // body, on a 200. The 401 case and this one must not disagree.
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      adapter.profilePayload = const {
        'success': 0,
        'error': 'Invalid userkey',
      };
      final res = await api.getProfile();

      expect(res.success, isFalse);
      expect(res.authRejected, isTrue);
      expect(notices, 1);
    });

    test('a rate limit is not a rejected session', () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      adapter
        ..profileStatusCode = 429
        ..profilePayload = const {
          'success': 0,
          'error': 'Too many requests, please try again later',
        };
      final res = await api.getProfile();

      // The one false-positive class this verdict cannot afford: a busy
      // line would otherwise delete a good password.
      expect(res.success, isFalse);
      expect(res.authRejected, isFalse);
      expect(notices, 0);
    });

    test('a wall page is not a rejected session', () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      adapter
        ..profileStatusCode = 503
        ..profileRawBody = '<html>Sorry, Cloudflare 503: Attention Required'
            '</html>';
      final res = await api.getProfile();

      expect(res.error, 'cf_blocked');
      expect(res.authRejected, isFalse);
      expect(notices, 0);
    });

    test('a page of rejections starts one notice, and a good answer re-arms',
        () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      adapter.profileStatusCode = 401;
      await api.getProfile();
      await api.getProfile();
      await api.getProfile();
      expect(notices, 1, reason: 'one re-verification, not one per request');

      adapter.profileStatusCode = 200;
      await api.getProfile();
      adapter.profileStatusCode = 401;
      await api.getProfile();
      expect(notices, 2, reason: 'a new episode gets a new notice');
    });

    test('an anonymous 401 says nothing about a stored pair', () async {
      // Nothing is installed, so there is no session to re-verify: firing
      // here would wake the auth layer on every public page that 401s.
      final adapter = _FakeAdapter()..profileStatusCode = 401;
      final api = _apiWith(adapter);
      var notices = 0;
      api.onSessionRejected = () => notices++;

      final res = await api.getProfile();

      expect(res.authRejected, isTrue);
      expect(notices, 0);
    });
  });

  group('file-link endpoint (S3)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('zlibx_link_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('JSON link response yields the link', () async {
      final adapter = _FakeAdapter();
      final api = await _loggedInApi(adapter);

      await api.downloadBook(_bookId, _bookHash, '${tempDir.path}/b.epub');

      expect(adapter.fileCalls, 1);
      expect(adapter.linkCalls, 1);
      expect(
        await File('${tempDir.path}/b.epub').readAsBytes(),
        _epubBytes,
      );
    });

    test('non-JSON 200 with a binary Content-Type is the file itself',
        () async {
      final adapter = _FakeAdapter()
        ..fileRawBody = _pdfBytes
        ..fileContentType = 'application/pdf';
      final api = await _loggedInApi(adapter);
      final path = '${tempDir.path}/b.pdf';

      await api.downloadBook(_bookId, _bookHash, path);

      // The endpoint itself streamed the file: no link request, the
      // endpoint URL is fetched a second time as the download (once
      // for the link lookup, once for the file).
      expect(adapter.fileCalls, 2);
      expect(adapter.linkCalls, 0);
      expect(await File(path).readAsBytes(), _pdfBytes);
    });

    test('the link lookup does not transfer the book twice', () async {
      final adapter = _FakeAdapter()
        ..fileRawBody = _bigEpub
        ..fileContentType = 'application/epub+zip';
      final api = await _loggedInApi(adapter);
      final path = '${tempDir.path}/b.epub';

      await api.downloadBook(_bookId, _bookHash, path);

      // Call 1 is the lookup, call 2 the download. dio pipes an
      // adapter stream eagerly, so the lookup cannot simply ignore
      // the body: it has to cancel, which stops the flow after at
      // most a chunk or two. Draining it (the old behaviour) moved
      // the whole 4 KB and only then asked for the file again.
      expect(adapter.fileBytesDelivered[1], _bigEpub.length);
      expect(
        adapter.fileBytesDelivered[0],
        lessThan(_bigEpub.length ~/ 4),
        reason: 'the lookup must abandon the body, not read it',
      );
      expect(adapter.fileAborts, 1, reason: 'the probe was cancelled');
      expect(await File(path).readAsBytes(), _bigEpub);
    });

    test('JSON error response fails with the server message', () async {
      final adapter = _FakeAdapter()
        ..fileJson = {'success': 0, 'error': 'download limit reached'};
      final api = await _loggedInApi(adapter);

      await expectLater(
        api.downloadBook(
          _bookId,
          _bookHash,
          '${tempDir.path}/b.epub',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message.toString(),
            'message',
            contains('download limit reached'),
          ),
        ),
      );
      expect(adapter.fileCalls, 1);
      expect(adapter.linkCalls, 0);
    });

    test('non-JSON 200 with text/html fails instead of being a file',
        () async {
      final adapter = _FakeAdapter()
        ..fileRawBody = _htmlBytes
        ..fileContentType = 'text/html';
      final api = await _loggedInApi(adapter);

      await expectLater(
        api.downloadBook(_bookId, _bookHash, '${tempDir.path}/b.epub'),
        throwsA(isA<StateError>()),
      );
      expect(adapter.fileCalls, 1);
      expect(adapter.linkCalls, 0);
    });
  });
}
