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
//  * Large files are never held in memory: downloads and /book stream
//    from disk (Range / If-Range / ETag so a browser can resume), the
//    zip is generated on the fly ([StreamingZip]), and TXT -> EPUB
//    conversion runs in a background isolate and is served from its
//    cache file, not from a byte buffer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:path/path.dart' as p;

import '../providers/download_task.dart';
import '../utils/diagnostics.dart';
import 'app_icon.dart';
import 'media_store.dart';
import 'reader_formats.dart';
import 'saf_folder_access.dart';
import 'streaming_zip.dart';
import 'txt_to_epub.dart';
import 'web_reader_page.dart';

/// The fixed port. See the lifecycle notes above.
const int kWebServicePort = 8080;

/// Which page shell a list page (/ and /search) is served with.
enum WebLayout {
  /// Full-width main area, poem on top.
  pc,

  /// Single column: stacked card rows, same header arrangement.
  mobile,
}

/// Pick the shell for a request: `?layout=pc|mobile` forces one
/// (handy for testing both shells from one device; any other value
/// falls back to the User-Agent), otherwise a mobile User-Agent
/// (Mobile / Android / iPhone / iPad / iPod / Windows Phone,
/// case-insensitive) means mobile, anything else PC.
WebLayout detectWebLayout({
  required Map<String, String> query,
  required Map<String, String> headers,
}) {
  final forced = (query['layout'] ?? '').toLowerCase();
  if (forced == 'pc') return WebLayout.pc;
  if (forced == 'mobile') return WebLayout.mobile;
  final ua = (headers['user-agent'] ?? '').toLowerCase();
  const mobileTokens = <String>[
    'mobile',
    'android',
    'iphone',
    'ipad',
    'ipod',
    'windows phone',
  ];
  if (mobileTokens.any(ua.contains)) return WebLayout.mobile;
  return WebLayout.pc;
}

/// Colour scheme of a list page. [auto] follows the system
/// (`prefers-color-scheme`); [light] / [dark] are forced by `?theme=`.
enum WebTheme { auto, light, dark }

/// `?theme=light|dark` forces one scheme (the page then carries a
/// `theme-light` / `theme-dark` class on `<body>`); any other value
/// falls back to [WebTheme.auto], i.e. the system setting.
WebTheme detectWebTheme(Map<String, String> query) {
  final forced = (query['theme'] ?? '').toLowerCase();
  if (forced == 'light') return WebTheme.light;
  if (forced == 'dark') return WebTheme.dark;
  return WebTheme.auto;
}

/// Format a byte count as "12.3 MB" (one decimal; B/KB/MB/GB).
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// Truncate a description to about two lines on a card (rune-safe).
/// Longer text gets an ellipsis; the CSS line-clamp is a second net.
String truncateDescription(String s, {int maxRunes = 120}) {
  if (s.runes.length <= maxRunes) return s;
  return '${String.fromCharCodes(s.runes.take(maxRunes))}…';
}

/// Strip HTML tags and decode entities from a server-supplied
/// description, so raw `<p>` markup never shows up on a card.
/// Tags are replaced with a space first (a block boundary stays a
/// word boundary), entities decoded after, so a literal `&lt;p&gt;`
/// in the text is not mistaken for a tag; the result is collapsed
/// to single spaces and trimmed. `&amp;` decodes last so `&amp;lt;`
/// stays the literal text `&lt;` instead of `<`.
String stripHtml(String s) {
  var text = s.replaceAll(RegExp(r'<[^>]*>'), ' ');
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m[1]!);
    if (code == null || code < 0 || code > 0x10FFFF) return m[0]!;
    return String.fromCharCode(code);
  });
  text = text.replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m[1]!, radix: 16);
    if (code == null || code < 0 || code > 0x10FFFF) return m[0]!;
    return String.fromCharCode(code);
  });
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ───────────────────────── Snapshot ─────────────────────────

/// One downloaded file that can be served.
class WebFile {
  /// The Z-Library book id (used by the zip routes).
  final int bookId;
  final String title;
  final String author;
  final String extension;

  /// Remote cover URL (Z-Library), if the book has one. The browser
  /// loads it directly; a missing cover gets a first-letter tile.
  final String? coverUrl;

  /// Human-readable file size ("12.3 MB"), or null when unknown.
  final String? sizeLabel;

  /// The book's synopsis, if Z-Library has one.
  final String? description;

  /// Stored location: a plain path or a MediaStore content:// URI.
  final String location;

  const WebFile({
    required this.bookId,
    required this.title,
    required this.author,
    required this.extension,
    this.coverUrl,
    this.sizeLabel,
    this.description,
    required this.location,
  });
}

/// One row in a list. [fileIndex] is the index into
/// [WebSnapshot.files] when the book is on this phone, else null (the
/// row is information only).
class WebEntry {
  /// The Z-Library book id, when known (used by the
  /// web-triggered download). Null only for rows built without a Book.
  final int? bookId;
  final String title;
  final String author;
  final String extension;

  /// Remote cover URL (Z-Library), if the book has one.
  final String? coverUrl;
  final int? fileIndex;

  /// Human-readable file size, when the book is downloaded.
  final String? sizeLabel;

  /// The book's synopsis, if Z-Library has one.
  final String? description;

  /// True when a download task exists for this book but has not
  /// finished (downloading / queued / paused): the web page shows
  /// "downloading" instead of offering to start another one.
  final bool downloadPending;

  const WebEntry({
    this.bookId,
    required this.title,
    required this.author,
    required this.extension,
    this.coverUrl,
    this.fileIndex,
    this.sizeLabel,
    this.description,
    this.downloadPending = false,
  });
}

/// Everything the web pages show, frozen when the service starts.
class WebSnapshot {
  final List<WebFile> files;
  final List<WebEntry> library;

  /// Book ids with a download task that has not finished
  /// (downloading / queued / paused). The web page shows
  /// "downloading" for these instead of offering to start another.
  final Set<int> pendingBookIds;

  const WebSnapshot({
    this.files = const <WebFile>[],
    this.library = const <WebEntry>[],
    this.pendingBookIds = const <int>{},
  });

  /// The two counts shown in settings.
  int get downloadedCount => files.length;
  int get libraryCount => library.length;

  /// The index of a downloaded file by its book id, or null.
  int? fileIndexForBookId(int bookId) {
    for (var i = 0; i < files.length; i++) {
      if (files[i].bookId == bookId) return i;
    }
    return null;
  }

  /// Build the snapshot from app data.
  ///
  /// * [tasks]: the download list; only completed tasks whose file
  ///   still exists are served.
  /// * [saved]: the shelf (收藏). A saved book that is also downloaded
  ///   gets the download link.
  factory WebSnapshot.build({
    required List<DownloadTask> tasks,
    required List<Book> saved,
  }) {
    final files = <WebFile>[];
    final indexById = <String, int>{};
    final pendingBookIds = <int>{
      for (final task in tasks)
        if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.pending ||
            task.status == DownloadStatus.paused)
          task.book.id,
    };
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
          bookId: task.book.id,
          title: task.book.title,
          author: task.book.author ?? '',
          extension: ext,
          coverUrl: task.book.cover,
          sizeLabel: _sizeLabelFor(task),
          description: task.book.description,
          location: location,
        ),
      );
    }

    WebEntry entryFor(Book book) {
      final index = indexById['${book.id}'];
      return WebEntry(
        bookId: book.id,
        title: book.title,
        author: book.author ?? '',
        extension: index != null
            ? files[index].extension
            : (book.extension ?? '').toLowerCase(),
        coverUrl: book.cover,
        fileIndex: index,
        sizeLabel: index != null ? files[index].sizeLabel : null,
        description: book.description,
        downloadPending:
            index == null && pendingBookIds.contains(book.id),
      );
    }

    return WebSnapshot(
      files: files,
      library: [for (final book in saved) entryFor(book)],
      pendingBookIds: pendingBookIds,
    );
  }

  /// Human-readable size for a downloaded file: the task's own
  /// byte count first (the real file size), then the book's
  /// server-reported size, then its pre-formatted string.
  static String? _sizeLabelFor(DownloadTask task) {
    final bytes = task.fileSize ?? task.book.filesize;
    if (bytes != null) return formatFileSize(bytes);
    final s = task.book.filesizeString;
    return (s == null || s.isEmpty) ? null : s;
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
  final String download;
  final String read;
  final String notDownloaded;
  final String empty;
  final String backHome;
  final String notFound;
  final String convertFailed;

  /// Link on the downloads heading row that reloads the page, so a
  /// reader sees a re-synced snapshot without finding the browser's
  /// own reload menu entry.
  final String refreshLink;

  const WebPageStrings({
    required this.homeTitle,
    required this.downloadedSection,
    required this.librarySection,
    required this.download,
    required this.read,
    required this.notDownloaded,
    required this.empty,
    required this.backHome,
    required this.notFound,
    required this.convertFailed,
    this.refreshLink = '',
  });

  /// English defaults (used by tests and as a safe fallback).
  static const WebPageStrings english = WebPageStrings(
    homeTitle: 'zlibx books',
    downloadedSection: 'Downloaded books',
    librarySection: 'Library',
    download: 'Download',
    read: 'Read',
    notDownloaded: 'not downloaded',
    empty: 'Nothing here',
    backHome: 'Back to home',
    notFound: 'Not found',
    convertFailed: 'This text file could not be converted for reading.',
    refreshLink: 'Refresh',
  );
}

// ───────────────────────── Response ─────────────────────────

/// One HTTP response, as decided by Dart and written by [_dispatch].
///
/// One answered request: [status], [headers], and exactly one payload
/// — [body] for small in-memory answers (HTML, plain text, reader
/// assets), [bodyStream] for a generated stream (the zip), or
/// [filePath] for a real file on disk
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

  /// A generated payload of known length (the zip): [_dispatch]
  /// calls it once per GET and pipes the stream to the socket, so the
  /// whole thing never sits in memory. [headers] must carry the exact
  /// Content-Length.
  final Stream<List<int>> Function()? bodyStream;

  const WebResponse({
    required this.status,
    this.headers = const <String, String>{},
    this.body,
    this.filePath,
    this.fileStart,
    this.fileEnd,
    this.bodyStream,
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

/// Outcome of a web-triggered download request (/request-download).
enum WebDownloadRequest {
  /// A new download round was started.
  started,

  /// The book is already on this phone.
  alreadyDownloaded,

  /// A download for this book is already running or queued.
  alreadyDownloading,

  /// No such book in the snapshot.
  notFound,
}

/// The settings page's answer to a web-triggered download: enqueue
/// the book with the app's own download logic. Must NOT start a
/// second round for a book that is already downloading or downloaded
/// — the caller checks that first and reports it instead.
typedef RequestDownloadHandler =
    Future<WebDownloadRequest> Function(int bookId);

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
       _resolvePath = pathResolver ?? _defaultResolvePath,
       _txt = txtConverter ?? TxtToEpub();

  /// Default path resolution: content:// URIs resolve through
  /// MediaStore to a real path; plain paths go through the SAF folder
  /// grant, so an orphaned file (stat-able but not openable) is
  /// materialized into the cache first. A file that opens directly
  /// passes through unchanged.
  static Future<String?> _defaultResolvePath(String location) async {
    if (MediaStoreFiles.isContentUri(location)) {
      return MediaStoreFiles.realPath(location);
    }
    return SafFolderAccess().readablePath(location);
  }

  HttpServer? _server;
  WebSnapshot _snapshot = const WebSnapshot();
  WebPageStrings _strings = WebPageStrings.english;

  /// Set by [start]: the screen's download trigger (item 3). Null
  /// when the caller did not provide it — that route then degrades.
  RequestDownloadHandler? _onRequestDownload;

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
  /// the one actually in use. [onRequestDownload] is the screen's
  /// callback for the web-triggered download.
  Future<int> start({
    required WebSnapshot snapshot,
    WebPageStrings strings = WebPageStrings.english,
    int preferredPort = kWebServicePort,
    RequestDownloadHandler? onRequestDownload,
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
    _pathCache.clear();
    _strings = strings;
    _onRequestDownload = onRequestDownload;
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

  /// Swap the served snapshot — and optionally the page strings and the
  /// download callback — WHILE RUNNING. Every new request reads the
  /// snapshot fresh, and streaming responses hold their own file
  /// handles, so nothing breaks: a browser only needs to reload the
  /// page to see the new state. No rebind, no lost connections.
  ///
  /// No-op while stopped (the next [start] picks the data up).
  /// [strings] / [onRequestDownload] are kept when omitted.
  void refresh({
    required WebSnapshot snapshot,
    WebPageStrings? strings,
    RequestDownloadHandler? onRequestDownload,
  }) {
    if (_server == null) return;
    _snapshot = snapshot;
    // Resolved paths belong to the old snapshot's locations.
    _pathCache.clear();
    if (strings != null) _strings = strings;
    if (onRequestDownload != null) _onRequestDownload = onRequestDownload;
    notifyListeners();
  }

  // ── Live snapshot source (background sync) ────────────────────────
  //
  // The download engine calls [markDownloadChanged] on meaningful
  // changes (task status transitions, removals, shelf changes); the
  // service rebuilds the snapshot through the registered builder and
  // swaps it in — no web service screen needs to be mounted for the
  // browser to catch up (a phone locked mid-reading still pushes).

  /// Registered by the web service screen at [start]: rebuilds the
  /// snapshot from live provider state (the download notifier reads
  /// its own tasks and the shelf provider — no widget refs involved).
  Future<WebSnapshot> Function()? _liveSnapshotBuilder;

  /// Rebuilt per swap so a web-triggered download always sees the
  /// current shelf.
  RequestDownloadHandler? _liveRequestDownload;
  Timer? _liveDebounce;

  /// Signature of the snapshot already swapped in, so progress-tick
  /// rebuilds with unchanged content do not churn the snapshot (and
  /// the resolved-path cache) for nothing.
  String _liveSignature = '';

  /// Register the live snapshot source. [onRequestDownload] is stored
  /// and re-wrapped per swap around the freshly built snapshot.
  void setLiveSource({
    required Future<WebSnapshot> Function() buildSnapshot,
    required RequestDownloadHandler onRequestDownload,
  }) {
    _liveSnapshotBuilder = buildSnapshot;
    _liveRequestDownload = onRequestDownload;
  }

  /// A meaningful download/shelf change happened. Coalesces bursts
  /// (a download round flips several tasks in quick succession) into
  /// one rebuild. No-op while stopped or without a live source.
  void markDownloadChanged() {
    if (_server == null || _liveSnapshotBuilder == null) return;
    _liveDebounce?.cancel();
    _liveDebounce = Timer(const Duration(milliseconds: 800), () {
      unawaited(_refreshFromLiveSource());
    });
  }

  Future<void> _refreshFromLiveSource() async {
    final builder = _liveSnapshotBuilder;
    if (_server == null || builder == null) return;
    final snapshot = await builder();
    if (_server == null) return;
    final signature = [
      for (final f in snapshot.files) '${f.bookId}:${f.coverUrl ?? ''}',
      for (final e in snapshot.library)
        '${e.bookId}:${e.fileIndex ?? -1}:${e.downloadPending ? 1 : 0}',
    ].join('|');
    if (signature == _liveSignature) return;
    _liveSignature = signature;
    refresh(snapshot: snapshot, onRequestDownload: _liveRequestDownload);
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
    _liveDebounce?.cancel();
    _pathCache.clear();
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
        } else if (response.bodyStream != null) {
          await httpResponse.addStream(response.bodyStream!());
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
      } catch (e) {
        // Response already started / closed: nothing more to do.
        logIgnored('web_service', e);
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
      // List pages (/ and /search) get a PC or mobile shell: the
      // layout is forced by ?layout=, else the User-Agent decides.
      final layout = detectWebLayout(query: query, headers: lowerHeaders);
      final theme = detectWebTheme(query);
      if (segments.isEmpty) {
        return _html(HttpStatus.ok, _homePage(layout, theme));
      }
      switch (segments.first) {
        case 'zip':
          return _zipRoute(segments);
        case 'request-download':
          return _requestDownloadRoute(segments);
        case 'icon.png':
        case 'favicon.ico':
          return _iconRoute();
        case 'download':
          return _downloadRoute(
            segments,
            lowerHeaders['range'],
            lowerHeaders['if-range'],
          );
        case 'read':
          return _readRoute(segments);
        case 'book':
          return _bookRoute(
            segments,
            lowerHeaders['range'],
            lowerHeaders['if-range'],
          );
        case 'reader-assets':
          return _assetRoute(segments);
        case 'search':
          return _searchRoute(query, layout, theme);
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

  /// Build a card row from a downloaded file (keeps the home page
  /// and the search results in sync with the detail page).
  WebEntry _entryFromFile(int index) {
    final f = _snapshot.files[index];
    return WebEntry(
      bookId: f.bookId,
      title: f.title,
      author: f.author,
      extension: f.extension,
      coverUrl: f.coverUrl,
      fileIndex: index,
      sizeLabel: f.sizeLabel,
      description: f.description,
    );
  }

  /// Zip download (item 2): /zip/all packs every downloaded book.
  /// The archive is generated on the fly ([StreamingZip]): books are
  /// read from disk chunk by chunk straight into the socket, stored
  /// uncompressed (they are already compressed formats), and the exact
  /// length is known up front so the browser shows real progress.
  /// Memory use stays flat however big the library is.
  Future<WebResponse> _zipRoute(List<String> s) async {
    List<int> indices;
    String zipName;
    if (s.length == 2 && s[1] == 'all') {
      indices = [for (var i = 0; i < _snapshot.files.length; i++) i];
      zipName = 'downloaded-books.zip';
    } else {
      return _notFound();
    }
    if (indices.isEmpty) {
      return _html(
        HttpStatus.ok,
        _messagePage('这里还没有已下载的书，打包是空的。'),
      );
    }
    final plan = <ZipPlanEntry>[];
    final usedNames = <String>{};
    for (final index in indices) {
      final file = await _fileFor(index);
      if (file == null) continue;
      final entry = _snapshot.files[index];
      final stat = await file.stat();
      var name = _zipEntryName(entry);
      var n = 2;
      while (usedNames.contains(name)) {
        name = _zipEntryName(entry, suffix: n);
        n++;
      }
      usedNames.add(name);
      plan.add(
        ZipPlanEntry(
          name: name,
          path: file.path,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    if (plan.isEmpty) {
      return _html(
        HttpStatus.ok,
        _messagePage('这里还没有已下载的书，打包是空的。'),
      );
    }
    final zip = StreamingZip(plan);
    return WebResponse(
      status: HttpStatus.ok,
      headers: <String, String>{
        'Content-Type': 'application/zip',
        'Content-Length': zip.length.toString(),
        'Content-Disposition': _contentDisposition(zipName),
      },
      bodyStream: zip.stream,
    );
  }

  /// A safe, unique file name inside the zip: "Title - Author.ext"
  /// with path-unsafe characters replaced.
  String _zipEntryName(WebFile f, {int? suffix}) {
    final base = [
      f.title,
      if (f.author.isNotEmpty) f.author,
    ].join(' - ').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final ext = f.extension.isNotEmpty ? '.${f.extension}' : '';
    final stem = base.isEmpty ? 'book' : base;
    return suffix == null ? '$stem$ext' : '$stem ($suffix)$ext';
  }

  /// Web-triggered download (item 3): `/request-download/<bookId>`.
  /// Hands the book to the screen's downloader and answers with a
  /// confirmation page. The snapshot is frozen at start, so a book
  /// downloaded this way only shows up after the service restarts —
  /// the confirmation says so.
  Future<WebResponse> _requestDownloadRoute(List<String> s) async {
    if (s.length != 2 || !RegExp(r'^\d{1,9}$').hasMatch(s[1])) {
      return _notFound();
    }
    final handler = _onRequestDownload;
    if (handler == null) {
      return _html(
        HttpStatus.ok,
        _messagePage('下载功能当前不可用，请在手机上直接下载。'),
      );
    }
    final bookId = int.parse(s[1]);
    WebDownloadRequest outcome;
    try {
      outcome = await handler(bookId);
    } catch (error) {
      logIgnored('web_service', error);
      return _plain(HttpStatus.internalServerError, 'Internal Server Error');
    }
    switch (outcome) {
      case WebDownloadRequest.started:
        return _html(
          HttpStatus.ok,
          _messagePage(
            '已开始下载，会占用下载额度。下载完成后重启 Web 服务，'
            '才能在网页上看到这本书。',
          ),
        );
      case WebDownloadRequest.alreadyDownloaded:
        return _html(HttpStatus.ok, _messagePage('这本书已经下载过了。'));
      case WebDownloadRequest.alreadyDownloading:
        return _html(HttpStatus.ok, _messagePage('这本书正在下载中，请稍后再来。'));
      case WebDownloadRequest.notFound:
        return _notFound();
    }
  }

  /// The app icon (item 8): /icon.png and /favicon.ico serve the
  /// same bytes, so "add to home screen" gets an icon. The icon is
  /// embedded as a base64 constant (see app_icon.dart) rather than
  /// a Flutter asset, because the push tooling only carries UTF-8
  /// text files — the bytes are the launcher icon's, unchanged.
  WebResponse _iconRoute() {
    final bytes = base64Decode(kAppIconBase64);
    return WebResponse(
      status: HttpStatus.ok,
      headers: <String, String>{
        'Content-Type': 'image/png',
        'Content-Length': bytes.length.toString(),
      },
      body: Uint8List.fromList(bytes),
    );
  }

  /// Search downloaded books and the library by a title/author
  /// substring (case-insensitive). A library row that points at a
  /// downloaded file already in the results is not listed twice.
  /// Renders the same book cards as the home page; an empty query
  /// shows the empty state.
  WebResponse _searchRoute(
    Map<String, String> query,
    WebLayout layout,
    WebTheme theme,
  ) {
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
          cards.add(_bookCard(_entryFromFile(i)));
        }
      }
      for (final e in _snapshot.library) {
        if ((hit(e.title) || hit(e.author)) &&
            (e.fileIndex == null || !matchedFiles.contains(e.fileIndex))) {
          cards.add(_bookCard(e));
        }
      }
    }
    return _html(HttpStatus.ok, _searchPage(q, cards, layout, theme));
  }

  /// Resolved real paths by snapshot index. Resolving can be
  /// expensive — an orphaned file is MATERIALIZED (copied) through the
  /// SAF grant — and a reader that pages through a big book issues
  /// hundreds of Range requests, so the answer is remembered for the
  /// life of the snapshot (and re-checked with a cheap exists()).
  final Map<int, String> _pathCache = <int, String>{};

  Future<File?> _fileFor(int index) async {
    final cached = _pathCache[index];
    if (cached != null) {
      final known = File(cached);
      if (await known.exists()) return known;
      _pathCache.remove(index);
    }
    final path = await _resolvePath(_snapshot.files[index].location);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    _pathCache[index] = path;
    return file;
  }

  Future<WebResponse> _downloadRoute(
    List<String> s,
    String? rangeHeader,
    String? ifRange,
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
      ifRange: ifRange,
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
        await _txt.epubFileFor(file.path, title: entry.title);
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

  Future<WebResponse> _bookRoute(
    List<String> s,
    String? rangeHeader,
    String? ifRange,
  ) async {
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
      // Served from the converter's cache FILE (streamed, Range-able):
      // a converted novel can be tens of MB and the reader page pages
      // through it with Range requests.
      final File epub;
      try {
        epub = await _txt.epubFileFor(file.path, title: entry.title);
      } on TxtConvertException {
        return _plain(HttpStatus.unprocessableEntity, 'convert failed');
      }
      return _sendFile(
        epub,
        contentType: 'application/epub+zip',
        downloadName: null,
        rangeHeader: rangeHeader,
        ifRange: ifRange,
        extraHeaders: const <String, String>{'X-Book-Name': 'book.epub'},
      );
    }
    return _sendFile(
      file,
      contentType: _mimeFor(ext),
      downloadName: null,
      rangeHeader: rangeHeader,
      ifRange: ifRange,
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
        // ~200 KB of reader JS; no need to re-fetch it (one TCP
        // connection per file, no keep-alive) on every book open.
        'Cache-Control': 'public, max-age=600',
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
        // The pages are dynamic (the snapshot swaps under them): never
        // let a browser answer a reload from its cache.
        'Cache-Control': 'no-store',
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

  /// Describe [file] for [_dispatch] to stream straight from disk
  /// (never copied to a cache first). Supports a single
  /// `Range: bytes=a-b` so interrupted downloads can resume.
  ///
  /// The response carries a strong `ETag` (size + mtime) and
  /// `Last-Modified`. Browsers (Chrome / Edge / Firefox) only resume
  /// an interrupted download when the server offers a validator they
  /// can send back in `If-Range`; without one a half-finished
  /// multi-hundred-MB download restarts from zero. A request whose
  /// `If-Range` no longer matches (the file was replaced) gets the
  /// whole file with 200 instead of a splice of two different files.
  ///
  /// [extraHeaders] are extra response headers (e.g. X-Book-Name);
  /// [rangeHeader] / [ifRange] are the request's `Range` / `If-Range`.
  Future<WebResponse> _sendFile(
    File file, {
    required String contentType,
    String? downloadName,
    String? rangeHeader,
    String? ifRange,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final stat = await file.stat();
    final length = stat.size;
    final etag =
        '"${length.toRadixString(16)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(16)}"';
    final lastModified = HttpDate.format(stat.modified.toUtc());
    var start = 0;
    var end = length - 1;
    var status = HttpStatus.ok;

    var rangeAllowed = rangeHeader != null;
    final validator = ifRange?.trim();
    if (rangeAllowed && validator != null && validator.isNotEmpty) {
      // A weak validator (W/"...") never matches for If-Range.
      rangeAllowed = validator.startsWith('"')
          ? validator == etag
          : validator == lastModified;
    }

    if (rangeAllowed) {
      final match = RegExp(
        r'^bytes=(\d*)-(\d*)$',
      ).firstMatch(rangeHeader!.trim());
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
      'ETag': etag,
      'Last-Modified': lastModified,
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
  // One shell for both layouts (see [detectWebLayout]): no sidebar.
  // The poem sits at the top-left of the main area, and each page
  // puts its own search box on its first heading row ([_headingRow])
  // — the "downloads" heading on the home page, the results heading
  // on the search page. The main area is a grid of borderless book
  // cards (cover left, title / author · format / actions right);
  // on mobile the grid degrades to a plain vertical stack of
  // horizontal card rows. The grid also degrades to a vertical stack
  // on readers that do not understand CSS grid.

  // Theme: the zlibx app's own look — forest green primary, rose-gold
  // accent, warm-paper background (values from the app's
  // app_colors.dart / app_theme.dart). Light is the default; dark
  // follows the system (`prefers-color-scheme`) or `?theme=dark|light`
  // (body class `theme-dark` / `theme-light`). Only the visual layer
  // changes; the layout (poem on top, search on the heading row,
  // horizontal book cards) is unchanged.
  //
  // E-reader browsers are old: no CSS variables, no min()/clamp(),
  // no flex `gap` for the card internals, no JS. Colours are written
  // out per rule, and the dark scheme is the same rule set emitted
  // twice by [_darkRules] (once under the media query, once under the
  // forced `body.theme-dark`), so nothing depends on newer CSS.
  static const String _font =
      '-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",'
      '"Hiragino Sans GB","Microsoft YaHei",Roboto,sans-serif';
  // easeOutCubic; app press feedback = scale 0.96 over 150ms.
  static const String _ease = 'cubic-bezier(0.215,0.61,0.355,1)';
  static const String _shadow = '0 6px 16px rgba(0,0,0,0.06)';

  static const String _lightCss =
      'body{margin:0;font-family:$_font;font-size:16px;line-height:1.5;'
      'color:#1A2421;background:#F8F7F5;color-scheme:light}'
      '.poem{color:#2D6A4F;letter-spacing:0.1em;margin:4px 0 24px}'
      '.head-row{display:flex;align-items:center;justify-content:space-between;'
      'gap:16px;flex-wrap:wrap;margin:8px 0 16px}'
      '.head-row h1,.head-row h2{margin:0;border-top:none;padding-top:0;'
      'flex:1 1 auto;min-width:0}'
      '.head-row .search{flex:0 1 320px;min-width:200px;margin:0}'
      '.head-row .refresh{flex:0 0 auto;font-size:14px;font-weight:600;text-decoration:none}'
      '.search input{width:100%;box-sizing:border-box;border:1.5px solid transparent;'
      'border-radius:30px;padding:16px 24px;font-size:16px;line-height:1.5;'
      '-webkit-appearance:none;appearance:none;background:#FFFFFF;color:#1A2421;'
      'box-shadow:$_shadow;transition:border-color 200ms $_ease}'
      '.search input:focus{outline:none;border-color:#2D6A4F}'
      '.main{padding:24px 20px 32px}'
      '.m-main{padding:24px 20px 32px}'
      'h1,h2{font-size:24px;font-weight:700;line-height:1.3;color:#1A2421}'
      'h2{margin:32px 0 16px;padding-top:24px;border-top:1px solid #E3E8E5}'
      // grid with a vertical-stack fallback: readers without CSS grid
      // see plain block-level cards, which already carry their own
      // bottom margin.
      '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));'
      'grid-column-gap:16px;column-gap:16px}'
      '.card{display:flex;align-items:flex-start;min-width:0;background:#FFFFFF;'
      'border:1px solid transparent;border-radius:20px;padding:16px;margin-bottom:16px;'
      'box-shadow:$_shadow}'
      '.cover{width:90px;height:120px;flex:0 0 90px;margin-right:16px;'
      'object-fit:cover;border-radius:8px;background:#EEF2EF}'
      '.cover-ph{width:90px;height:120px;flex:0 0 90px;margin-right:16px;'
      'border-radius:8px;background:#E8F5EE;color:#2D6A4F;'
      'display:flex;align-items:center;justify-content:center;font-size:32px;font-weight:700}'
      '.info{flex:1;min-width:0}'
      '.name{font-weight:700;color:#1A2421;word-wrap:break-word}'
      '.meta{color:#5C6B64;font-size:12px;margin-top:2px}'
      '.desc{color:#5C6B64;font-size:12px;margin-top:4px;max-height:3em;'
      'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}'
      '.actions{margin-top:12px}'
      '.actions a{display:inline-block;border-radius:30px;padding:8px 20px;'
      'margin:0 8px 4px 0;font-size:14px;font-weight:600;line-height:1.4;'
      'text-decoration:none;color:#FFFFFF;background:#2D6A4F;'
      'transition:transform 150ms $_ease,background-color 150ms $_ease}'
      '.actions a+a{background:#E8F5EE;color:#2D6A4F}'
      '.actions a:hover{background:#245A42}'
      '.actions a+a:hover{background:#D3EBDD}'
      '.dim{color:#5C6B64}'
      '.zip-btn{display:inline-block;margin:0 0 16px;padding:16px 24px;border-radius:30px;'
      'font-size:16px;font-weight:600;text-decoration:none;color:#FFFFFF;background:#2D6A4F;'
      'transition:transform 150ms $_ease,background-color 150ms $_ease}'
      '.zip-btn:hover{background:#245A42}'
      '.actions a:active,.zip-btn:active{transform:scale(0.96)}'
      'a{color:#2D6A4F}'
      // Page margins follow the app: 20 on phones, 32 from 600, 48 from 1240.
      '@media (min-width:600px){.main{padding:24px 32px 32px}}'
      '@media (min-width:1240px){.main{padding:24px 48px 32px}}'
      // Mobile shell overrides (body.layout-mobile): the grid becomes
      // one stacked column of horizontal card rows with a smaller
      // cover and thumb-friendly buttons.
      'body.layout-mobile .grid{display:block}'
      'body.layout-mobile .cover,body.layout-mobile .cover-ph{width:64px;height:84px;flex-basis:64px}'
      'body.layout-mobile .cover-ph{font-size:26px}'
      'body.layout-mobile .actions a{padding:12px 20px;font-size:16px}';

  /// The dark scheme (app dark palette), scoped under [b] — the body
  /// selector that switches it on.
  static String _darkRules(String b) =>
      '$b{color:#E6ECE7;background:#121712;color-scheme:dark}'
      '$b .poem{color:#52B788}'
      '$b h1,$b h2,$b .name{color:#E6ECE7}'
      '$b h2{border-top-color:#2A2F2A}'
      '$b .search input{background:#252D26;color:#E6ECE7;box-shadow:none}'
      '$b .search input:focus{border-color:#52B788}'
      '$b .card{background:#1B221C;border-color:#2A2F2A;box-shadow:none}'
      '$b .cover{background:#252D26}'
      '$b .cover-ph{background:#1F3F2F;color:#52B788}'
      '$b .meta,$b .desc,$b .dim{color:#B2BDB4}'
      '$b a{color:#52B788}'
      '$b .actions a,$b .zip-btn{background:#52B788;color:#0F2418}'
      '$b .actions a+a{background:#1F3F2F;color:#52B788}'
      '$b .actions a:hover,$b .zip-btn:hover{background:#6BC79B}'
      '$b .actions a+a:hover{background:#2A5340}';

  static final String _css =
      '$_lightCss'
      '@media (prefers-color-scheme:dark){${_darkRules('body:not(.theme-light)')}}'
      '${_darkRules('body.theme-dark')}';

  /// Every page carries its layout on the `<body>` so tests (and CSS)
  /// can tell the shells apart: `layout-pc` or `layout-mobile`, plus
  /// `theme-light` / `theme-dark` when `?theme=` forces a scheme.
  /// Message pages ([_messagePage]) keep the PC shell.
  String _page(
    String title,
    String body, {
    WebLayout layout = WebLayout.pc,
    WebTheme theme = WebTheme.auto,
  }) {
    final layoutCls = layout == WebLayout.mobile
        ? 'layout-mobile'
        : 'layout-pc';
    final cls = theme == WebTheme.light
        ? '$layoutCls theme-light'
        : theme == WebTheme.dark
        ? '$layoutCls theme-dark'
        : layoutCls;
    return '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<link rel="icon" type="image/png" href="/icon.png">'
        '<link rel="apple-touch-icon" href="/icon.png">'
        '<title>${escapeHtml(title)}</title><style>$_css</style></head>'
        '<body class="$cls">$body</body></html>';
  }

  /// Every page shares this shell: no sidebar — the poem sits at the
  /// top-left of the main area, and the page's own content follows.
  String _layout(String main) =>
      '<main class="main"><div class="poem">邂逅相遇，适我愿兮</div>$main</main>';

  /// The mobile shell: the same arrangement as PC — poem on top,
  /// content below. No sidebar, nothing hover-dependent.
  String _mobileLayout(String main) =>
      '<main class="m-main"><div class="poem">邂逅相遇，适我愿兮</div>$main</main>';

  /// A section heading with the search box on the same row, right
  /// end: the heading takes the free space, the form keeps a fixed-ish
  /// width, and the row wraps on narrow screens so the box is never
  /// squeezed away.
  String _headingRow(String heading, {String searchValue = ''}) {
    final value = searchValue.isEmpty
        ? ''
        : ' value="${escapeHtml(searchValue)}"';
    // An empty href navigates to the current URL: a plain reload that
    // picks up the phone's latest snapshot without breaking anything.
    final refresh = _strings.refreshLink.isEmpty
        ? ''
        : '<a class="refresh" href="">${escapeHtml(_strings.refreshLink)}</a>';
    return '<div class="head-row">$heading'
        '<form class="search" method="get" action="/search">'
        '<input name="q" type="search"$value>'
        '</form>$refresh</div>';
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
  /// the left, title / author · format · size / description / actions
  /// on the right. A downloaded book gets [Download] and, when it
  /// can be opened, [Read] —
  /// foliate formats go to /read, a PDF goes straight to /book so
  /// the browser's own PDF viewer opens it. A book that is not on
  /// this phone gets a "download to phone" trigger link, unless a
  /// download for it is already running — then it just says
  /// "downloading". (Legado shows chapter counts and read progress
  /// here; zlibx has no such data, so its lines are title,
  /// author · format · size, description, actions.)
  String _bookCard(WebEntry e) {
    final b = StringBuffer('<article class="card">');
    final cover = e.coverUrl;
    if (cover != null && cover.isNotEmpty) {
      // A remote (Z-Library / Anna's Archive) URL can be dead or
      // hotlink-protected — the browser then shows a broken image with
      // the alt text, and the card loses its cover box. Swap it, in
      // place, for the same first-letter tile a no-cover book gets: one
      // cover box size for every card, nothing stays broken. Inline
      // attribute handler, not a <script> tag — the page still ships no
      // script tag.
      b.write(
        '<img class="cover" src="${escapeHtml(cover)}" loading="lazy" '
        'alt="${escapeHtml(e.title)}" '
        'data-ph="${escapeHtml(_firstChar(e.title))}" '
        "onerror=\"var p=document.createElement('div');"
        "p.className='cover-ph';p.setAttribute('aria-hidden','true');"
        "p.textContent=this.dataset.ph||'?';this.replaceWith(p)\">",
      );
    } else {
      b.write(
        '<div class="cover-ph" aria-hidden="true">'
        '${escapeHtml(_firstChar(e.title))}</div>',
      );
    }
    b.write('<div class="info">');
    final title = escapeHtml(e.title);
    b.write('<div class="name">$title</div>');
    final meta = [
      if (e.author.isNotEmpty) e.author,
      if (e.extension.isNotEmpty) e.extension.toUpperCase(),
      if (e.sizeLabel != null && e.sizeLabel!.isNotEmpty) e.sizeLabel!,
    ].join(' • ');
    if (meta.isNotEmpty) {
      b.write('<div class="meta">${escapeHtml(meta)}</div>');
    }
    final desc = e.description;
    if (desc != null) {
      final clean = stripHtml(desc).trim();
      if (clean.isNotEmpty) {
        b.write(
          '<div class="desc">${escapeHtml(truncateDescription(clean))}</div>',
        );
      }
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
    } else if (e.downloadPending) {
      b.write(
        '<div class="actions"><span class="dim">正在下载…</span></div>',
      );
    } else if (e.bookId != null) {
      b.write(
        '<div class="actions">'
        '<a href="/request-download/${e.bookId}">下载到手机</a>'
        '</div>',
      );
    } else {
      b.write(
        '<div class="actions"><span class="dim">'
        '${escapeHtml(_strings.notDownloaded)}</span></div>',
      );
    }
    b.write('</div></article>');
    return b.toString();
  }

  String _grid(Iterable<String> cards) => cards.isEmpty
      ? '<p class="dim">${escapeHtml(_strings.empty)}</p>'
      : '<div class="grid">${cards.join()}</div>';

  String _homePage(WebLayout layout, [WebTheme theme = WebTheme.auto]) {
    final downloaded = [
      for (var i = 0; i < _snapshot.files.length; i++) _bookCard(_entryFromFile(i)),
    ];
    final library = _snapshot.library.map(_bookCard);
    final packAll = downloaded.isEmpty
        ? ''
        : ' <a class="zip-btn" href="/zip/all">全部打包</a>';
    final main =
        '${_headingRow(
          '<h2 id="downloaded">${escapeHtml(_strings.downloadedSection)} (${downloaded.length})</h2>',
        )}'
        '$packAll'
        '${_grid(downloaded)}'
        '<h2 id="library">${escapeHtml(_strings.librarySection)} (${library.length})</h2>'
        '${_grid(library)}';
    return _page(
      _strings.homeTitle,
      layout == WebLayout.mobile ? _mobileLayout(main) : _layout(main),
      layout: layout,
      theme: theme,
    );
  }

  /// Search results, in the same shell: the search term at the top,
  /// a link back home, and the matching cards (or the empty state).
  /// The search box stays on the results heading row, so the term
  /// can be changed without going back home.
  String _searchPage(
    String q,
    List<String> cards,
    WebLayout layout, [
    WebTheme theme = WebTheme.auto,
  ]) {
    final main =
        '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
        '${_headingRow('<h1>搜索“${escapeHtml(q)}”</h1>', searchValue: q)}'
        '${_grid(cards)}';
    return _page(
      '搜索“$q”',
      layout == WebLayout.mobile ? _mobileLayout(main) : _layout(main),
      layout: layout,
      theme: theme,
    );
  }

}
