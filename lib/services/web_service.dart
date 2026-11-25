// The LAN web service: lets other devices on the same hotspot / Wi-Fi
//   * download the books on this phone from a plain-HTML home page
//     (no JavaScript, so e-readers and weak browsers work), and
//   * read shelf books in the user's own desktop browser through the
//     vendored foliate-js reader (/read, /book, /reader-assets).
//
// The HTTP transport is a plain Dart [HttpServer]: one 0.0.0.0 socket on
// the fixed port 8080. An earlier native Kotlin rewrite (LanWebServer)
// was reverted — it was built on a misdiagnosis. The server had
// stopped accepting connections from other devices, and the socket
// was blamed, but the real cause was Android 17's local-network
// protection: targetSdk 37 apps need the ACCESS_LOCAL_NETWORK runtime
// permission, without it inbound TCP from other devices times out in
// the network stack before the SYN reaches any socket (Legado targets
// a lower SDK and is exempt). So [start] asks the native side
// (MethodChannel "zlibx/local_network") to ensure the permission is
// granted before binding. Dart answers each request through
// [handleRequest], which returns a [WebResponse] descriptor; [_dispatch]
// writes the status line, headers and body to the HttpResponse
// (streaming files from disk with Range support).
//
// Lifecycle rules (each one cost a delivery before):
//  * [WebService.shared] is a process singleton. The settings page may
//    be left and re-entered freely; ONLY [stop] (the Stop button) stops
//    the server. Never call stop from a widget's dispose().
//  * Port 8080 is fixed; only when it cannot be bound does the server
//    fall back to a system-chosen port, and [port] is always the one
//    actually in use.
//  * The book lists are a snapshot taken at start; they do not follow
//    later downloads / favourites. Restarting refreshes them.
//  * Files are addressed ONLY by their index in the snapshot — a
//    request path never names a file system path.
//  * Every response is answered with `Connection: close`: one request
//    per connection, no keep-alive.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:path/path.dart' as p;

import '../providers/download_task.dart';
import '../utils/diagnostics.dart';
import 'media_store.dart';
import 'txt_to_epub.dart';
import 'web_reader_page.dart';

/// The fixed port. See the lifecycle notes above.
const int kWebServicePort = 8080;

/// The only files /reader-assets/ will ever serve (the 13 vendored
/// foliate-js files). Anything else is a 404.
const Set<String> kReaderAssetWhitelist = <String>{
  'view.js',
  'epubcfi.js',
  'progress.js',
  'overlayer.js',
  'text-walker.js',
  'epub.js',
  'mobi.js',
  'fb2.js',
  'comic-book.js',
  'paginator.js',
  'fixed-layout.js',
  'vendor/zip.js',
  'vendor/fflate.js',
};

/// Formats the reader can open. PDF is not opened by the reader —
/// a desktop browser renders it with its own PDF viewer through
/// /book instead (see [isPdfExtension]). DRM is not handled at all.
const Set<String> kReadableExtensions = <String>{
  'epub',
  'mobi',
  'azw3',
  'fb2',
  'cbz',
  'txt',
};

bool isReadableExtension(String? extension) =>
    kReadableExtensions.contains((extension ?? '').toLowerCase());

/// A PDF is viewable in the browser itself: /book serves it inline
/// (no Content-Disposition: attachment), so Chrome / Edge / Firefox
/// open it in their built-in PDF viewer. The foliate reader cannot
/// open PDFs, so /read still refuses them.
bool isPdfExtension(String? extension) =>
    (extension ?? '').toLowerCase() == 'pdf';

// ───────────────────────── Snapshot ─────────────────────────

/// One downloaded file that can be served.
class WebFile {
  final String title;
  final String author;
  final String extension;

  /// Remote cover URL (Z-Library), if the book has one. The browser
  /// loads it directly; a missing cover gets a first-letter tile.
  final String? coverUrl;

  /// Stored location: a plain path or a MediaStore content:// URI.
  final String location;

  const WebFile({
    required this.title,
    required this.author,
    required this.extension,
    this.coverUrl,
    required this.location,
  });
}

/// One row in a list. [fileIndex] is the index into
/// [WebSnapshot.files] when the book is on this phone, else null (the
/// row is information only).
class WebEntry {
  final String title;
  final String author;
  final String extension;

  /// Remote cover URL (Z-Library), if the book has one.
  final String? coverUrl;
  final int? fileIndex;

  const WebEntry({
    required this.title,
    required this.author,
    required this.extension,
    this.coverUrl,
    this.fileIndex,
  });
}

class WebBooklist {
  final String id;
  final String name;

  /// The booklist's full page on the Z-Library mirror.
  final String url;
  final int? count;

  /// Preview books only (what the booklist's card carried).
  final List<WebEntry> books;

  const WebBooklist({
    required this.id,
    required this.name,
    required this.url,
    required this.count,
    required this.books,
  });
}

/// Everything the web pages show, frozen when the service starts.
class WebSnapshot {
  final List<WebFile> files;
  final List<WebEntry> library;
  final List<WebBooklist> booklists;

  const WebSnapshot({
    this.files = const <WebFile>[],
    this.library = const <WebEntry>[],
    this.booklists = const <WebBooklist>[],
  });

  /// The three counts shown in settings.
  int get downloadedCount => files.length;
  int get libraryCount => library.length;
  int get booklistCount => booklists.length;

  /// Build the snapshot from app data.
  ///
  /// * [tasks]: the download list; only completed tasks whose file
  ///   still exists are served.
  /// * [saved]: the shelf (收藏). A saved book that is also downloaded
  ///   gets the download link.
  /// * [booklists]: the user's booklists, with their preview books.
  factory WebSnapshot.build({
    required List<DownloadTask> tasks,
    required List<Book> saved,
    required List<Booklist> booklists,
  }) {
    final files = <WebFile>[];
    final indexById = <String, int>{};
    for (final task in tasks) {
      final location = task.filePath;
      if (task.status != DownloadStatus.completed ||
          task.missingFile ||
          location == null ||
          location.isEmpty) {
        continue;
      }
      if (indexById.containsKey(task.id)) continue;
      final ext = _extensionOf(task.book.extension, location);
      indexById[task.id] = files.length;
      files.add(
        WebFile(
          title: task.book.title,
          author: task.book.author ?? '',
          extension: ext,
          coverUrl: task.book.cover,
          location: location,
        ),
      );
    }

    WebEntry entryFor(Book book) {
      final index = indexById['${book.id}'];
      return WebEntry(
        title: book.title,
        author: book.author ?? '',
        extension: index != null
            ? files[index].extension
            : (book.extension ?? '').toLowerCase(),
        coverUrl: book.cover,
        fileIndex: index,
      );
    }

    return WebSnapshot(
      files: files,
      library: [for (final book in saved) entryFor(book)],
      booklists: [
        for (final list in booklists)
          WebBooklist(
            id: list.id,
            name: list.name,
            url: list.url,
            count: list.count,
            books: [for (final book in list.previewBooks) entryFor(book)],
          ),
      ],
    );
  }

  static String _extensionOf(String? declared, String location) {
    final d = (declared ?? '').trim().toLowerCase();
    if (d.isNotEmpty) return d;
    final dot = p.extension(location).replaceFirst('.', '').toLowerCase();
    return dot;
  }
}

/// Text for the plain-HTML pages, supplied by the app (localized) so
/// this service stays free of any BuildContext.
class WebPageStrings {
  final String homeTitle;
  final String downloadedSection;
  final String librarySection;
  final String booklistSection;
  final String download;
  final String read;
  final String notDownloaded;
  final String empty;
  final String backHome;
  final String officialLink;
  final String previewNote;
  final String notFound;
  final String convertFailed;

  const WebPageStrings({
    required this.homeTitle,
    required this.downloadedSection,
    required this.librarySection,
    required this.booklistSection,
    required this.download,
    required this.read,
    required this.notDownloaded,
    required this.empty,
    required this.backHome,
    required this.officialLink,
    required this.previewNote,
    required this.notFound,
    required this.convertFailed,
  });

  /// English defaults (used by tests and as a safe fallback).
  static const WebPageStrings english = WebPageStrings(
    homeTitle: 'zlibx books',
    downloadedSection: 'Downloaded books',
    librarySection: 'Library',
    booklistSection: 'Booklists',
    download: 'Download',
    read: 'Read',
    notDownloaded: 'not downloaded',
    empty: 'Nothing here',
    backHome: 'Back to home',
    officialLink: 'Full list on Z-Library',
    previewNote: 'Preview books only',
    notFound: 'Not found',
    convertFailed: 'This text file could not be converted for reading.',
  );
}

// ───────────────────────── Response ─────────────────────────

/// One HTTP response, as decided by Dart and written by [_dispatch].
///
/// One answered request: [status], [headers], and exactly one payload
/// — [body] for small in-memory answers (HTML, plain text, reader
/// assets, converted EPUBs), or [filePath] for a real file on disk
/// that [_dispatch] streams, bytes [fileStart]..[fileEnd] inclusive
/// (null start = 0, null end = end of file). [headers] always carries
/// Content-Type and Content-Length (and Content-Range for a 206), so
/// [_dispatch] never has to guess a length. For a HEAD request the
/// descriptor is the same as for GET — [_dispatch], not the router,
/// drops the body.
///
/// A 416 carries `Content-Length: 0` (dart:io would otherwise send it
/// chunked, which bare-bones clients handle worse). Same status, same
/// Content-Range.
class WebResponse {
  final int status;
  final Map<String, String> headers;
  final Uint8List? body;
  final String? filePath;
  final int? fileStart;
  final int? fileEnd;

  const WebResponse({
    required this.status,
    this.headers = const <String, String>{},
    this.body,
    this.filePath,
    this.fileStart,
    this.fileEnd,
  });
}

// ───────────────────────── Service ─────────────────────────

typedef AssetLoader = Future<List<int>?> Function(String assetPath);
typedef PathResolver = Future<String?> Function(String location);

Future<List<int>?> _bundleAsset(String assetPath) async {
  try {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

/// Thrown by [WebService.start] when the user denies the local-network
/// permission. The settings page catches it and shows a localized hint
/// (grant "Nearby devices" in system settings) instead of the generic
/// start-failed message.
class LocalNetworkPermissionDenied implements Exception {
  const LocalNetworkPermissionDenied();
}

class WebService extends ChangeNotifier {
  /// The one instance shared by the settings page and the server.
  static final WebService shared = WebService();

  /// The only native call the service needs: the Android 17
  /// local-network permission (MethodChannel "zlibx/local_network",
  /// `ensureLocalNetworkPermission`). Everything else is Dart.
  static const MethodChannel _permissionChannel =
      MethodChannel('zlibx/local_network');

  final AssetLoader _loadAsset;
  final PathResolver _resolvePath;
  final TxtToEpub _txt;

  WebService({
    AssetLoader? assetLoader,
    PathResolver? pathResolver,
    TxtToEpub? txtConverter,
  }) : _loadAsset = assetLoader ?? _bundleAsset,
       _resolvePath = pathResolver ?? MediaStoreFiles.realPath,
       _txt = txtConverter ?? TxtToEpub();

  HttpServer? _server;
  WebSnapshot _snapshot = const WebSnapshot();
  WebPageStrings _strings = WebPageStrings.english;

  bool get isRunning => _server != null;

  /// The port actually bound, or null when stopped.
  int? get port => _server?.port;

  WebSnapshot get snapshot => _snapshot;

  /// Start serving [snapshot]. Idempotent: starting while running just
  /// returns the current port (the snapshot is NOT replaced — stop and
  /// start again to refresh it).
  ///
  /// Binds one 0.0.0.0 socket on [preferredPort]; when that port is
  /// taken, a system-chosen port is used instead, and [port] is always
  /// the one actually in use.
  Future<int> start({
    required WebSnapshot snapshot,
    WebPageStrings strings = WebPageStrings.english,
    int preferredPort = kWebServicePort,
  }) async {
    final running = _server;
    if (running != null) return running.port;

    // Android 17+ (targetSdk 37) blocks local-network sockets without
    // the ACCESS_LOCAL_NETWORK runtime permission: without it, inbound
    // TCP from other devices times out in the network stack, before
    // the SYN ever reaches our socket. Ask the native side to make
    // sure it is granted before binding.
    if (!await _ensureLocalNetworkPermission()) {
      throw const LocalNetworkPermissionDenied();
    }

    _snapshot = snapshot;
    _strings = strings;
    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
      );
    } on SocketException {
      // Preferred port taken by another program: any free port.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(
      _dispatch,
      onError: (Object e) => logIgnored('web_service', e),
    );
    notifyListeners();
    return server.port;
  }

  /// Ask the native side to ensure the local-network permission is
  /// granted (Android 17+ only; older Android answers true at once).
  /// Returns false when the user denied it. A missing channel method
  /// (unit tests, older builds) counts as granted — there is no such
  /// gate on those platforms.
  Future<bool> _ensureLocalNetworkPermission() async {
    try {
      return await _permissionChannel.invokeMethod<bool>(
            'ensureLocalNetworkPermission',
          ) ??
          true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Stop serving. Called ONLY from the Stop button.
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await server.close(force: true);
    notifyListeners();
  }

  /// One incoming connection: route it through [handleRequest] and
  /// write the descriptor to the response. [request.uri.path] is
  /// already percent-decoded by dart:io and has no query string;
  /// header names are lowered here so `range` is always found.
  /// [request.uri.queryParameters] is passed through for /search.
  Future<void> _dispatch(HttpRequest request) async {
    try {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      final response = await handleRequest(
        method: request.method,
        path: request.uri.path,
        query: request.uri.queryParameters,
        headers: headers,
      );
      final httpResponse = request.response;
      httpResponse.statusCode = response.status;
      response.headers.forEach((name, value) {
        httpResponse.headers.set(name, value);
      });
      // One request per connection, as documented above.
      httpResponse.persistentConnection = false;
      final isHead = request.method.toUpperCase() == 'HEAD';
      if (!isHead) {
        final filePath = response.filePath;
        if (filePath != null) {
          final file = File(filePath);
          final start = response.fileStart ?? 0;
          final end = response.fileEnd;
          await httpResponse.addStream(
            file.openRead(start, end == null ? null : end + 1),
          );
        } else if (response.body != null) {
          httpResponse.add(response.body!);
        }
      }
      await httpResponse.close();
    } catch (error) {
      logIgnored('web_service', error);
      try {
        final httpResponse = request.response;
        httpResponse.statusCode = HttpStatus.internalServerError;
        httpResponse.persistentConnection = false;
        httpResponse.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/plain; charset=utf-8',
        );
        httpResponse.write('Internal Server Error');
        await httpResponse.close();
      } catch (_) {
        // Response already started / closed: nothing more to do.
      }
    }
  }

  // ── Routing ──────────────────────────────────────────────────────

  /// Answer one HTTP request, as a [WebResponse] for [_dispatch] to
  /// write. Pure apart from file reads and TXT conversion, so it
  /// is unit-testable without any socket. [path] is the percent-
  /// decoded request path (query string already stripped);
  /// [query] is the decoded query string, used by /search;
  /// [headers] may use any casing (only `range` is read); keys are
  /// normalised to lowercase on entry.
  Future<WebResponse> handleRequest({
    required String method,
    required String path,
    Map<String, String> query = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      // Header names are case-insensitive: [_dispatch] already
      // lowercases them, but a direct caller (tests, future
      // transports) may pass 'Range'. Normalise once so `range` is
      // always found.
      final lowerHeaders = <String, String>{
        for (final entry in headers.entries)
          entry.key.toLowerCase(): entry.value,
      };
      final normalizedMethod = method.toUpperCase();
      if (normalizedMethod != 'GET' && normalizedMethod != 'HEAD') {
        return _plain(HttpStatus.methodNotAllowed, 'Method Not Allowed');
      }
      final segments = path
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.isEmpty) {
        return _html(HttpStatus.ok, _homePage());
      }
      switch (segments.first) {
        case 'booklist':
          return _booklistRoute(segments);
        case 'download':
          return _downloadRoute(segments, lowerHeaders['range']);
        case 'read':
          return _readRoute(segments);
        case 'book':
          return _bookRoute(segments, lowerHeaders['range']);
        case 'reader-assets':
          return _assetRoute(segments);
        case 'search':
          return _searchRoute(query);
        default:
          return _notFound();
      }
    } catch (error) {
      logIgnored('web_service', error);
      return _plain(
        HttpStatus.internalServerError,
        'Internal Server Error',
      );
    }
  }

  /// Strict index parse: digits only, within the snapshot's files.
  int? _fileIndex(List<String> segments) {
    if (segments.length != 2) return null;
    final raw = segments[1];
    if (!RegExp(r'^\d{1,9}$').hasMatch(raw)) return null;
    final index = int.parse(raw);
    return index < _snapshot.files.length ? index : null;
  }

  WebResponse _notFound() =>
      _html(HttpStatus.notFound, _messagePage(_strings.notFound));

  WebResponse _booklistRoute(List<String> s) {
    if (s.length != 2) return _notFound();
    for (final list in _snapshot.booklists) {
      if (list.id == s[1]) {
        return _html(HttpStatus.ok, _booklistPage(list));
      }
    }
    return _notFound();
  }

  /// Search downloaded books and the library by a title/author
  /// substring (case-insensitive). A library row that points at a
  /// downloaded file already in the results is not listed twice.
  /// Renders the same book cards as the home page; an empty query
  /// shows the empty state.
  WebResponse _searchRoute(Map<String, String> query) {
    final q = (query['q'] ?? '').trim();
    final needle = q.toLowerCase();
    bool hit(String s) => s.toLowerCase().contains(needle);
    final cards = <String>[];
    final matchedFiles = <int>{};
    if (needle.isNotEmpty) {
      for (var i = 0; i < _snapshot.files.length; i++) {
        final f = _snapshot.files[i];
        if (hit(f.title) || hit(f.author)) {
          matchedFiles.add(i);
          cards.add(
            _bookCard(
              WebEntry(
                title: f.title,
                author: f.author,
                extension: f.extension,
                coverUrl: f.coverUrl,
                fileIndex: i,
              ),
            ),
          );
        }
      }
      for (final e in _snapshot.library) {
        if ((hit(e.title) || hit(e.author)) &&
            (e.fileIndex == null || !matchedFiles.contains(e.fileIndex))) {
          cards.add(_bookCard(e));
        }
      }
    }
    return _html(HttpStatus.ok, _searchPage(q, cards));
  }

  Future<File?> _fileFor(int index) async {
    final path = await _resolvePath(_snapshot.files[index].location);
    if (path == null) return null;
    final file = File(path);
    return await file.exists() ? file : null;
  }

  Future<WebResponse> _downloadRoute(
    List<String> s,
    String? rangeHeader,
  ) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound();
    final file = await _fileFor(index);
    if (file == null) return _notFound();
    return _sendFile(
      file,
      contentType: _mimeFor(_snapshot.files[index].extension),
      downloadName: p.basename(file.path),
      rangeHeader: rangeHeader,
    );
  }

  Future<WebResponse> _readRoute(List<String> s) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound();
    final entry = _snapshot.files[index];
    if (!isReadableExtension(entry.extension)) return _notFound();
    final file = await _fileFor(index);
    if (file == null) return _notFound();

    if (entry.extension.toLowerCase() == 'txt') {
      // Convert up front so a failure becomes a readable page here
      // rather than a broken reader; /book then hits the cache.
      try {
        await _txt.epubFor(file.path, title: entry.title);
      } on TxtConvertException {
        return _html(
          HttpStatus.unprocessableEntity,
          _messagePage(_strings.convertFailed),
        );
      }
    }
    return _html(
      HttpStatus.ok,
      buildReaderPage(
        index: index,
        title: entry.title,
        bookKey: fnv1a64Hex(entry.location),
      ),
    );
  }

  Future<WebResponse> _bookRoute(List<String> s, String? rangeHeader) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound();
    final entry = _snapshot.files[index];
    if (!isReadableExtension(entry.extension) &&
        !isPdfExtension(entry.extension)) {
      return _notFound();
    }
    final file = await _fileFor(index);
    if (file == null) return _notFound();

    final ext = entry.extension.toLowerCase();
    if (ext == 'txt') {
      final Uint8List epub;
      try {
        epub = await _txt.epubFor(file.path, title: entry.title);
      } on TxtConvertException {
        return _plain(HttpStatus.unprocessableEntity, 'convert failed');
      }
      return WebResponse(
        status: HttpStatus.ok,
        headers: <String, String>{
          'Content-Type': 'application/epub+zip',
          'X-Book-Name': 'book.epub',
          'Content-Length': epub.length.toString(),
        },
        body: epub,
      );
    }
    return _sendFile(
      file,
      contentType: _mimeFor(ext),
      downloadName: null,
      rangeHeader: rangeHeader,
      extraHeaders: <String, String>{'X-Book-Name': 'book.$ext'},
    );
  }

  Future<WebResponse> _assetRoute(List<String> s) async {
    final name = s.sublist(1).join('/');
    if (!kReaderAssetWhitelist.contains(name)) return _notFound();
    final bytes = await _loadAsset('assets/web-reader/$name');
    if (bytes == null) return _notFound();
    return WebResponse(
      status: HttpStatus.ok,
      headers: <String, String>{
        'Content-Type': 'text/javascript; charset=utf-8',
        'Content-Length': bytes.length.toString(),
      },
      body: Uint8List.fromList(bytes),
    );
  }

  // ── Responses ────────────────────────────────────────────────────

  WebResponse _html(int status, String body) {
    final bytes = utf8.encode(body);
    return WebResponse(
      status: status,
      headers: <String, String>{
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': bytes.length.toString(),
      },
      body: Uint8List.fromList(bytes),
    );
  }

  WebResponse _plain(int status, String body) {
    final bytes = utf8.encode(body);
    return WebResponse(
      status: status,
      headers: <String, String>{
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': bytes.length.toString(),
      },
      body: Uint8List.fromList(bytes),
    );
  }

  /// Describe [file] for the native side to stream straight from disk
  /// (never copied to a cache first). Supports a single
  /// `Range: bytes=a-b` so interrupted downloads can resume.
  /// [extraHeaders] are extra response headers (e.g. X-Book-Name);
  /// [rangeHeader] is the request's `Range` value, if any.
  Future<WebResponse> _sendFile(
    File file, {
    required String contentType,
    String? downloadName,
    String? rangeHeader,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final length = await file.length();
    var start = 0;
    var end = length - 1;
    var status = HttpStatus.ok;

    if (rangeHeader != null) {
      final match = RegExp(
        r'^bytes=(\d*)-(\d*)$',
      ).firstMatch(rangeHeader.trim());
      if (match != null && (match[1]!.isNotEmpty || match[2]!.isNotEmpty)) {
        if (match[1]!.isEmpty) {
          final suffix = int.tryParse(match[2]!) ?? 0;
          start = (length - suffix).clamp(0, length).toInt();
        } else {
          start = int.tryParse(match[1]!) ?? length;
          if (match[2]!.isNotEmpty) end = int.tryParse(match[2]!) ?? end;
        }
        if (end > length - 1) end = length - 1;
        if (start > end || start >= length) {
          return WebResponse(
            status: HttpStatus.requestedRangeNotSatisfiable,
            headers: <String, String>{
              'Content-Range': 'bytes */$length',
              'Content-Length': '0',
            },
          );
        }
        status = HttpStatus.partialContent;
      }
    }

    final count = length == 0 ? 0 : end - start + 1;
    final headers = <String, String>{
      'Content-Type': contentType,
      'Accept-Ranges': 'bytes',
      'Content-Length': count.toString(),
      ...extraHeaders,
    };
    if (status == HttpStatus.partialContent) {
      headers['Content-Range'] = 'bytes $start-$end/$length';
    }
    if (downloadName != null) {
      headers['Content-Disposition'] = _contentDisposition(downloadName);
    }
    if (count == 0) {
      return WebResponse(status: status, headers: headers, body: Uint8List(0));
    }
    return WebResponse(
      status: status,
      headers: headers,
      filePath: file.path,
      fileStart: start,
      fileEnd: end,
    );
  }

  static String _contentDisposition(String name) {
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7E]'), '_').replaceAll(
      RegExp(r'["\\]'),
      '_',
    );
    return 'attachment; filename="$ascii"; '
        "filename*=UTF-8''${Uri.encodeComponent(name)}";
  }

  static String _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'epub':
        return 'application/epub+zip';
      case 'pdf':
        return 'application/pdf';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw3':
      case 'azw':
        return 'application/vnd.amazon.ebook';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'cbz':
        return 'application/vnd.comicbook+zip';
      case 'txt':
        return 'text/plain; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  // ── Plain-HTML pages (NO JavaScript — e-readers must work) ───────
  //
  // Layout, after Legado's web bookshelf: a light-grey sidebar on
  // the left (title, poem, search box, recent-reading and settings
  // sections, GitHub link at the bottom) and the white main area on
  // the right, where each section is a grid of borderless book cards
  // (cover left, title / author · format / actions right). On a
  // narrow screen the sidebar stacks above the main area. The grid
  // degrades to a plain vertical stack on readers that do not
  // understand CSS grid.

  static const String _css =
      'body{font-family:sans-serif;margin:0;line-height:1.5;color:#222}'
      '.layout{display:flex;min-height:100vh}'
      '.sidebar{flex:0 0 220px;background:#f5f5f5;padding:1.4em 1em;'
      'display:flex;flex-direction:column}'
      '.side-title{font-size:1.6em;font-weight:700}'
      '.side-sub{color:#666;font-size:0.95em;margin:0.4em 0 1.2em}'
      '.search input{width:100%;box-sizing:border-box;border:1px solid #dcdfe6;'
      'border-radius:16px;padding:0.45em 0.9em;font-size:0.95em;background:#fff}'
      '.side-sec{margin-top:1.6em}'
      '.side-sec h3{font-size:1em;margin:0 0 0.6em;color:#333}'
      '.tag{display:inline-block;border-radius:4px;padding:0.2em 0.7em;font-size:0.9em}'
      '.tag-warn{background:#fdf6ec;color:#e6a23c;border:1px solid #faecd8}'
      '.tag-info{background:#ecf5ff;color:#409eff;border:1px solid #d9ecff}'
      '.github{margin-top:auto;padding-top:2em;color:#666;text-decoration:none;font-size:0.9em}'
      '.main{flex:1;min-width:0;padding:1em 1.4em 2em;background:#fff}'
      'h1{font-size:1.3em}'
      'h2{font-size:1.1em;margin:1.6em 0 0.6em;border-bottom:1px solid #e4e7ed;padding-bottom:0.2em}'
      '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1.4em 1.2em}'
      '.card{display:flex;gap:0.8em}'
      '.cover{width:90px;height:120px;flex:0 0 90px;object-fit:cover;background:#eee}'
      '.cover-ph{width:90px;height:120px;flex:0 0 90px;background:#7a8699;color:#fff;'
      'display:flex;align-items:center;justify-content:center;font-size:2em}'
      '.info{flex:1;min-width:0}'
      '.name{font-weight:700}'
      '.meta{color:#666;font-size:0.9em}'
      '.actions{margin-top:0.4em}'
      '.actions a{display:inline-block;border:1px solid #888;border-radius:4px;'
      'padding:0.15em 0.8em;margin-right:0.5em;text-decoration:none;color:#222}'
      '.list-card{display:block;padding:0.6em 0;text-decoration:none;color:#222}'
      '.dim{color:#888}'
      'a{color:#0645ad}'
      '@media (max-width:640px){.layout{display:block}.sidebar{width:auto}}';

  String _page(String title, String body) =>
      '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>${escapeHtml(title)}</title><style>$_css</style></head>'
      '<body>$body</body></html>';

  /// Every page shares this shell: the sidebar on the left, the
  /// page's own content in the white main area on the right.
  String _layout(String main, {String searchValue = ''}) =>
      '<div class="layout">${_sidebar(searchValue: searchValue)}'
      '<main class="main">$main</main></div>';

  /// The sidebar, after Legado's bookshelf: title, poem, a working
  /// search box (plain GET form, no JS), recent reading (the server
  /// cannot know the browser's reading progress, so it honestly
  /// shows the empty state), settings (a "connected" tag — no URL,
  /// the browser's address bar already shows it), GitHub at the
  /// bottom. The labels are Legado's fixed UI copy, so they are
  /// literal here rather than localised strings.
  String _sidebar({String searchValue = ''}) {
    final value = searchValue.isEmpty
        ? ''
        : ' value="${escapeHtml(searchValue)}"';
    return '<aside class="sidebar">'
        '<div class="side-title">${escapeHtml(_strings.homeTitle)}</div>'
        '<div class="side-sub">清风不识字，何故乱翻书</div>'
        '<form class="search" method="get" action="/search">'
        '<input name="q" type="search" '
        'placeholder="搜索书籍，在线书籍自动加入书架"$value>'
        '</form>'
        '<div class="side-sec"><h3>最近阅读</h3>'
        '<span class="tag tag-warn">尚无阅读记录</span></div>'
        '<div class="side-sec"><h3>基本设定</h3>'
        '<span class="tag tag-info">已连接</span></div>'
        '<a class="github" href="https://github.com/minglaiyo/zlibx">'
        'GitHub</a>'
        '</aside>';
  }

  String _messagePage(String message) => _page(
    message,
    _layout(
      '<p>${escapeHtml(message)}</p>'
      '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>',
    ),
  );

  /// First character of [title], for the no-cover tile ('?' when empty).
  static String _firstChar(String title) =>
      title.isEmpty ? '?' : String.fromCharCode(title.runes.first);

  /// One book card, after Legado's bookshelf: borderless, cover on
  /// the left, title / author · format / actions on the right. A
  /// downloaded book gets [Download] and, when it can be opened,
  /// [Read] — foliate formats go to /read, a PDF goes straight to
  /// /book so the browser's own PDF viewer opens it. A book that is
  /// not on this phone shows only "not downloaded", with no buttons.
  /// (Legado shows chapter counts and read progress here; zlibx has
  /// no such data, so its lines are title, author · format, actions.)
  String _bookCard(WebEntry e) {
    final b = StringBuffer('<article class="card">');
    final cover = e.coverUrl;
    if (cover != null && cover.isNotEmpty) {
      b.write(
        '<img class="cover" src="${escapeHtml(cover)}" loading="lazy" '
        'alt="${escapeHtml(e.title)}">',
      );
    } else {
      b.write(
        '<div class="cover-ph" aria-hidden="true">'
        '${escapeHtml(_firstChar(e.title))}</div>',
      );
    }
    b.write('<div class="info">');
    b.write('<div class="name">${escapeHtml(e.title)}</div>');
    final meta = [
      if (e.author.isNotEmpty) e.author,
      if (e.extension.isNotEmpty) e.extension.toUpperCase(),
    ].join(' • ');
    if (meta.isNotEmpty) {
      b.write('<div class="meta">${escapeHtml(meta)}</div>');
    }
    final index = e.fileIndex;
    if (index != null) {
      b.write('<div class="actions">');
      b.write(
        '<a href="/download/$index">${escapeHtml(_strings.download)}</a>',
      );
      final ext = e.extension.toLowerCase();
      if (isReadableExtension(ext)) {
        b.write(' <a href="/read/$index">${escapeHtml(_strings.read)}</a>');
      } else if (isPdfExtension(ext)) {
        b.write(' <a href="/book/$index">${escapeHtml(_strings.read)}</a>');
      }
      b.write('</div>');
    } else {
      b.write(
        '<div class="actions"><span class="dim">'
        '${escapeHtml(_strings.notDownloaded)}</span></div>',
      );
    }
    b.write('</div></article>');
    return b.toString();
  }

  /// One booklist card: its name and book count, linking to the
  /// booklist page. Borderless, like the book cards.
  String _booklistCard(WebBooklist l) =>
      '<a class="list-card" href="/booklist/${Uri.encodeComponent(l.id)}">'
      '<div class="name">${escapeHtml(l.name)}</div>'
      '${l.count != null ? '<div class="meta">(${l.count})</div>' : ''}'
      '</a>';

  String _grid(Iterable<String> cards) => cards.isEmpty
      ? '<p class="dim">${escapeHtml(_strings.empty)}</p>'
      : '<div class="grid">${cards.join()}</div>';

  String _homePage() {
    final downloaded = [
      for (var i = 0; i < _snapshot.files.length; i++)
        _bookCard(
          WebEntry(
            title: _snapshot.files[i].title,
            author: _snapshot.files[i].author,
            extension: _snapshot.files[i].extension,
            coverUrl: _snapshot.files[i].coverUrl,
            fileIndex: i,
          ),
        ),
    ];
    final library = _snapshot.library.map(_bookCard);
    final lists = _snapshot.booklists.map(_booklistCard);
    return _page(
      _strings.homeTitle,
      _layout(
        '<h2 id="downloaded">${escapeHtml(_strings.downloadedSection)} (${downloaded.length})</h2>'
        '${_grid(downloaded)}'
        '<h2 id="library">${escapeHtml(_strings.librarySection)} (${library.length})</h2>'
        '${_grid(library)}'
        '<h2 id="booklists">${escapeHtml(_strings.booklistSection)} (${lists.length})</h2>'
        '${_grid(lists)}',
      ),
    );
  }

  /// Search results, in the same shell: the search term at the top,
  /// a link back home, and the matching cards (or the empty state).
  String _searchPage(String q, List<String> cards) => _page(
    '搜索“$q”',
    _layout(
      '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
      '<h1>搜索“${escapeHtml(q)}”</h1>'
      '${_grid(cards)}',
      searchValue: q,
    ),
  );

  String _booklistPage(WebBooklist list) {
    final link = list.url.startsWith('http')
        ? '<p><a href="${escapeHtml(list.url)}">'
              '${escapeHtml(_strings.officialLink)}</a></p>'
        : '';
    return _page(
      list.name,
      _layout(
        '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
        '<h1>${escapeHtml(list.name)}</h1>'
        '<p class="meta">${escapeHtml(_strings.previewNote)}</p>'
        '${_grid(list.books.map(_bookCard))}'
        '$link',
      ),
    );
  }
}
