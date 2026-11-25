// The LAN web service: lets other devices on the same hotspot / Wi-Fi
//   * download the books on this phone from a plain-HTML home page
//     (no JavaScript, so e-readers and weak browsers work), and
//   * read shelf books in the user's own desktop browser through the
//     vendored foliate-js reader (/read, /book, /reader-assets).
//
// The HTTP transport is NATIVE (LanWebServer.kt, MethodChannel
// "zlibx/web_server"): the Dart `HttpServer` (a single 0.0.0.0 socket
// and then one socket per detected address, ports 8080 and 8888)
// served loopback fine but never accepted a connection from another
// device on this phone, while Legado — a native Android app — serves
// the same phone without trouble. The one variable never changed in
// any attempt was the Dart socket itself. So this file owns the
// snapshot, the HTML pages, routing, Range parsing, TXT→EPUB
// conversion and the reader routes — and Kotlin owns sockets and
// bytes. Dart answers each request through [handleRequest], which
// returns a [WebResponse] descriptor; Kotlin writes the status line,
// headers and body (streaming files from disk with Range support).
//
// Lifecycle rules (each one cost a delivery before):
//  * [WebService.shared] is a process singleton. The settings page may
//    be left and re-entered freely; ONLY [stop] (the Stop button) stops
//    the server. Never call stop from a widget's dispose().
//  * Port 8888 is fixed; only when it cannot be bound does the native
//    side fall back to a system-chosen port (single 0.0.0.0 socket
//    only), and [port] is always the one actually in use.
//  * The server binds one socket per detected address (loopback plus
//    every address the picker found), not a single 0.0.0.0 socket.
//    With no detected addresses it falls back to the single 0.0.0.0
//    socket.
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
const int kWebServicePort = 8888;

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

/// Formats the reader can open (PDF is download-only; DRM is not
/// handled at all).
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

// ───────────────────────── Snapshot ─────────────────────────

/// One downloaded file that can be served.
class WebFile {
  final String title;
  final String author;
  final String extension;

  /// Stored location: a plain path or a MediaStore content:// URI.
  final String location;

  const WebFile({
    required this.title,
    required this.author,
    required this.extension,
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
  final int? fileIndex;

  const WebEntry({
    required this.title,
    required this.author,
    required this.extension,
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

/// One HTTP response, as decided by Dart and written by Kotlin.
///
/// Wire shape (MethodChannel "zlibx/web_server", `handleRequest`
/// reply): {status: int, headers: `Map<String, String>`,
/// body: Uint8List?, filePath: String?, fileStart: int?,
/// fileEnd: int?}. Exactly one of [body] / [filePath] carries the
/// payload: [body] for small in-memory answers (HTML, plain text,
/// reader assets, converted EPUBs), [filePath] for a real file on disk
/// that Kotlin streams, bytes [fileStart]..[fileEnd] inclusive
/// (null start = 0, null end = end of file). [headers] always carries
/// Content-Type and Content-Length (and Content-Range for a 206), so
/// Kotlin never has to guess a length. For a HEAD request the
/// descriptor is the same as for GET — Kotlin, not Dart, drops the
/// body.
///
/// One deliberate deviation from the old Dart server: a 416 used to
/// go out chunked (dart:io sent no Content-Length for it); it now
/// carries `Content-Length: 0`, which bare-bones clients handle
/// better. Same status, same Content-Range.
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

  Map<String, Object?> toMap() => <String, Object?>{
    'status': status,
    'headers': headers,
    'body': body,
    'filePath': filePath,
    'fileStart': fileStart,
    'fileEnd': fileEnd,
  };
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

class WebService extends ChangeNotifier {
  /// The one instance shared by the settings page and the server.
  static final WebService shared = WebService();

  /// The native transport (LanWebServer.kt). Dart calls `start` /
  /// `stop` on it; it calls back with `handleRequest`, answered by
  /// [shared] (the server only ever runs for the shared instance).
  static const MethodChannel _channel = MethodChannel('zlibx/web_server');

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

  bool _running = false;
  int? _port;
  WebSnapshot _snapshot = const WebSnapshot();
  WebPageStrings _strings = WebPageStrings.english;

  bool get isRunning => _running;

  /// The port actually bound, or null when stopped.
  int? get port => _port;

  WebSnapshot get snapshot => _snapshot;

  /// Start serving [snapshot]. Idempotent: starting while running just
  /// returns the current port (the snapshot is NOT replaced — stop and
  /// start again to refresh it).
  ///
  /// [bindAddresses] lists the addresses to listen on, one socket
  /// each. When it is null or empty the native side falls back to its
  /// single 0.0.0.0 socket (with a port-0 fallback if the preferred
  /// port is taken). A [PlatformException] with code BIND_FAILED
  /// means no address could be bound at all.
  Future<int> start({
    required WebSnapshot snapshot,
    WebPageStrings strings = WebPageStrings.english,
    int preferredPort = kWebServicePort,
    List<InternetAddress>? bindAddresses,
  }) async {
    if (_running) return _port!;

    _snapshot = snapshot;
    _strings = strings;
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      final args = <String, Object?>{
        'port': preferredPort,
        'addresses': <String>[
          for (final a in bindAddresses ?? const <InternetAddress>[])
            a.address,
        ],
      };
      final result = await _channel.invokeMethod<Object?>('start', args);
      final actual = result is int ? result : null;
      if (actual == null) {
        throw StateError('web_server: native start returned no port');
      }
      _port = actual;
      _running = true;
      notifyListeners();
      return actual;
    } catch (error) {
      // No server, so the handler would never be called.
      _channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  /// Stop serving. Called ONLY from the Stop button.
  Future<void> stop() async {
    if (!_running) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      logIgnored('web_service', error);
    }
    _running = false;
    _port = null;
    _channel.setMethodCallHandler(null);
    notifyListeners();
  }

  /// Incoming `handleRequest` calls from the native server. The
  /// native side already percent-decoded the path; [headers] arrives
  /// with lowercase keys.
  static Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method != 'handleRequest') {
      throw MissingPluginException('web_server: ${call.method}');
    }
    final args = call.arguments;
    if (args is! Map) {
      throw ArgumentError('web_server: handleRequest arguments must be a Map');
    }
    final headers = <String, String>{};
    final rawHeaders = args['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString().toLowerCase()] =
            entry.value?.toString() ?? '';
      }
    }
    final response = await shared.handleRequest(
      method: args['method']?.toString() ?? '',
      path: args['path']?.toString() ?? '/',
      headers: headers,
    );
    return response.toMap();
  }

  // ── Routing ──────────────────────────────────────────────────────

  /// Answer one HTTP request, as a [WebResponse] for the native side
  /// to write. Pure apart from file reads and TXT conversion, so it
  /// is unit-testable without any socket. [path] is the percent-
  /// decoded request path (query string already stripped by Kotlin);
  /// [headers] may use any casing (only `range` is read); keys are
  /// normalised to lowercase on entry.
  Future<WebResponse> handleRequest({
    required String method,
    required String path,
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      // Header names are case-insensitive: Kotlin already lowercases
      // them, but a direct caller (tests, future transports) may pass
      // 'Range'. Normalise once so `range` is always found.
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
    if (!isReadableExtension(entry.extension)) return _notFound();
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

  static const String _css =
      'body{font-family:sans-serif;margin:0 auto;max-width:46em;padding:0.8em;'
      'line-height:1.5}h1{font-size:1.3em}h2{font-size:1.1em;margin-top:1.6em;'
      'border-bottom:1px solid #999}li{margin:0.5em 0}.meta{color:#666;'
      'font-size:0.9em}.dim{color:#888}';

  String _page(String title, String body) =>
      '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>${escapeHtml(title)}</title><style>$_css</style></head>'
      '<body>$body</body></html>';

  String _messagePage(String message) => _page(
    message,
    '<p>${escapeHtml(message)}</p>'
    '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>',
  );

  String _row(WebEntry e) {
    final b = StringBuffer('<li>${escapeHtml(e.title)}');
    final meta = [
      if (e.author.isNotEmpty) e.author,
      if (e.extension.isNotEmpty) e.extension.toUpperCase(),
    ].join(' · ');
    if (meta.isNotEmpty) {
      b.write(' <span class="meta">${escapeHtml(meta)}</span>');
    }
    final index = e.fileIndex;
    if (index != null) {
      b.write(
        ' <a href="/download/$index">${escapeHtml(_strings.download)}</a>',
      );
      if (isReadableExtension(e.extension)) {
        b.write(' <a href="/read/$index">${escapeHtml(_strings.read)}</a>');
      }
    } else {
      b.write(' <span class="dim">(${escapeHtml(_strings.notDownloaded)})</span>');
    }
    b.write('</li>');
    return b.toString();
  }

  String _list(Iterable<String> rows) => rows.isEmpty
      ? '<p class="dim">${escapeHtml(_strings.empty)}</p>'
      : '<ul>${rows.join()}</ul>';

  String _homePage() {
    final downloaded = [
      for (var i = 0; i < _snapshot.files.length; i++)
        _row(
          WebEntry(
            title: _snapshot.files[i].title,
            author: _snapshot.files[i].author,
            extension: _snapshot.files[i].extension,
            fileIndex: i,
          ),
        ),
    ];
    final library = _snapshot.library.map(_row);
    final lists = [
      for (final l in _snapshot.booklists)
        '<li><a href="/booklist/${Uri.encodeComponent(l.id)}">'
            '${escapeHtml(l.name)}</a>'
            '${l.count != null ? ' <span class="meta">(${l.count})</span>' : ''}'
            '</li>',
    ];
    return _page(
      _strings.homeTitle,
      '<h1>${escapeHtml(_strings.homeTitle)}</h1>'
      '<h2>${escapeHtml(_strings.downloadedSection)} (${downloaded.length})</h2>'
      '${_list(downloaded)}'
      '<h2>${escapeHtml(_strings.librarySection)} (${library.length})</h2>'
      '${_list(library)}'
      '<h2>${escapeHtml(_strings.booklistSection)} (${lists.length})</h2>'
      '${_list(lists)}',
    );
  }

  String _booklistPage(WebBooklist list) {
    final link = list.url.startsWith('http')
        ? '<p><a href="${escapeHtml(list.url)}">'
              '${escapeHtml(_strings.officialLink)}</a></p>'
        : '';
    return _page(
      list.name,
      '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
      '<h1>${escapeHtml(list.name)}</h1>'
      '<p class="meta">${escapeHtml(_strings.previewNote)}</p>'
      '${_list(list.books.map(_row))}'
      '$link',
    );
  }
}
