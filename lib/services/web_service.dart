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

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:path/path.dart' as p;

import '../providers/download_task.dart';
import '../utils/diagnostics.dart';
import 'app_icon.dart';
import 'media_store.dart';
import 'reader_formats.dart';
import 'txt_to_epub.dart';
import 'web_reader_page.dart';

/// The fixed port. See the lifecycle notes above.
const int kWebServicePort = 8080;

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

// ───────────────────────── Snapshot ─────────────────────────

/// One downloaded file that can be served.
class WebFile {
  /// The Z-Library book id (used by /detail and the zip routes).
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

  /// Detail-page metadata, when the book carries it.
  final String? publisher;
  final int? year;
  final int? pages;
  final String? language;

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
    this.publisher,
    this.year,
    this.pages,
    this.language,
    required this.location,
  });
}

/// One row in a list. [fileIndex] is the index into
/// [WebSnapshot.files] when the book is on this phone, else null (the
/// row is information only).
class WebEntry {
  /// The Z-Library book id, when known (used by /detail and the
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

  /// Detail-page metadata, when the book carries it.
  final String? publisher;
  final int? year;
  final int? pages;
  final String? language;

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
    this.publisher,
    this.year,
    this.pages,
    this.language,
    this.downloadPending = false,
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

  /// Book ids with a download task that has not finished
  /// (downloading / queued / paused). The web page shows
  /// "downloading" for these instead of offering to start another.
  final Set<int> pendingBookIds;

  const WebSnapshot({
    this.files = const <WebFile>[],
    this.library = const <WebEntry>[],
    this.booklists = const <WebBooklist>[],
    this.pendingBookIds = const <int>{},
  });

  /// The three counts shown in settings.
  int get downloadedCount => files.length;
  int get libraryCount => library.length;
  int get booklistCount => booklists.length;

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
  /// * [booklists]: the user's booklists, with their preview books.
  factory WebSnapshot.build({
    required List<DownloadTask> tasks,
    required List<Book> saved,
    required List<Booklist> booklists,
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
          publisher: task.book.publisher,
          year: task.book.year,
          pages: task.book.pages,
          language: task.book.language,
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
        publisher: book.publisher,
        year: book.year,
        pages: book.pages,
        language: book.language,
        downloadPending:
            index == null && pendingBookIds.contains(book.id),
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

/// One fetched booklist page (item 6): the books and whether a next
/// page exists.
class WebBooklistPage {
  final List<Book> books;
  final bool hasMore;
  const WebBooklistPage({required this.books, required this.hasMore});
}

/// Fetch one page of a booklist from Z-Library (20 books per page,
/// like the site). Returns null when the page could not be fetched
/// (offline / 503 / challenge wall) — the service then falls back
/// to the snapshot's preview books.
typedef BooklistPageFetcher =
    Future<WebBooklistPage?> Function(String booklistId, int page);

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

  /// Set by [start]: the screen's download trigger (item 3) and
  /// booklist page fetcher (item 6). Null when the caller did not
  /// provide them — those routes then degrade to the snapshot.
  RequestDownloadHandler? _onRequestDownload;
  BooklistPageFetcher? _onFetchBooklistPage;

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
  /// the one actually in use. [onRequestDownload] and
  /// [onFetchBooklistPage] are the screen's callbacks for the
  /// web-triggered download and the on-demand booklist pages.
  Future<int> start({
    required WebSnapshot snapshot,
    WebPageStrings strings = WebPageStrings.english,
    int preferredPort = kWebServicePort,
    RequestDownloadHandler? onRequestDownload,
    BooklistPageFetcher? onFetchBooklistPage,
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
    _onRequestDownload = onRequestDownload;
    _onFetchBooklistPage = onFetchBooklistPage;
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
          return _booklistRoute(segments, query);
        case 'detail':
          return _detailRoute(segments);
        case 'zip':
          return _zipRoute(segments);
        case 'request-download':
          return _requestDownloadRoute(segments);
        case 'icon.png':
        case 'favicon.ico':
          return _iconRoute();
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

  /// One booklist page, loaded on demand (item 6): page N is fetched
  /// live from Z-Library (20 books per page, like the site) through
  /// the screen's fetcher; `?page=N` moves between pages. When the
  /// fetch fails (offline / 503 / challenge wall) or no fetcher was
  /// provided, the snapshot's preview books are shown instead, with
  /// a notice that the live load failed.
  Future<WebResponse> _booklistRoute(
    List<String> s,
    Map<String, String> query,
  ) async {
    if (s.length != 2) return _notFound();
    WebBooklist? found;
    for (final list in _snapshot.booklists) {
      if (list.id == s[1]) {
        found = list;
        break;
      }
    }
    if (found == null) return _notFound();
    final list = found;
    final page = int.tryParse(query['page'] ?? '1') ?? 1;
    final safePage = page < 1 ? 1 : page;
    final fetcher = _onFetchBooklistPage;
    if (fetcher != null) {
      WebBooklistPage? fetched;
      try {
        fetched = await fetcher(list.id, safePage);
      } catch (error) {
        logIgnored('web_service', error);
        fetched = null;
      }
      if (fetched != null) {
        final entries = [
          for (final book in fetched.books) _entryForFetchedBook(book),
        ];
        return _html(
          HttpStatus.ok,
          _booklistPage(
            list,
            entries,
            page: safePage,
            hasMore: fetched.hasMore,
            loadFailed: false,
            isPreview: false,
          ),
        );
      }
      return _html(
        HttpStatus.ok,
        _booklistPage(
          list,
          list.books,
          page: safePage,
          hasMore: false,
          loadFailed: true,
        ),
      );
    }
    return _html(
      HttpStatus.ok,
      _booklistPage(
        list,
        list.books,
        page: safePage,
        hasMore: false,
        loadFailed: false,
      ),
    );
  }

  /// Convert a live-fetched book into a card row: link it to a
  /// downloaded file when this phone has it, else mark it
  /// downloadable / downloading from the snapshot's state.
  WebEntry _entryForFetchedBook(Book book) {
    final index = _snapshot.fileIndexForBookId(book.id);
    return WebEntry(
      bookId: book.id,
      title: book.title,
      author: book.author ?? '',
      extension: index != null
          ? _snapshot.files[index].extension
          : (book.extension ?? '').toLowerCase(),
      coverUrl: book.cover,
      fileIndex: index,
      sizeLabel: index != null ? _snapshot.files[index].sizeLabel : null,
      description: book.description,
      publisher: book.publisher,
      year: book.year,
      pages: book.pages,
      language: book.language,
      downloadPending:
          index == null && _snapshot.pendingBookIds.contains(book.id),
    );
  }

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
      publisher: f.publisher,
      year: f.year,
      pages: f.pages,
      language: f.language,
    );
  }

  /// The detail page (item 5): `/detail/<bookId>`. A downloaded book
  /// is found in the files first; otherwise the library, then the
  /// booklist previews. Unknown ids are a 404.
  WebResponse _detailRoute(List<String> s) {
    if (s.length != 2 || !RegExp(r'^\d{1,9}$').hasMatch(s[1])) {
      return _notFound();
    }
    final bookId = int.parse(s[1]);
    final entry = _detailEntryForBookId(bookId);
    if (entry == null) return _notFound();
    return _html(HttpStatus.ok, _detailPage(entry));
  }

  WebEntry? _detailEntryForBookId(int bookId) {
    final fileIndex = _snapshot.fileIndexForBookId(bookId);
    if (fileIndex != null) return _entryFromFile(fileIndex);
    for (final e in _snapshot.library) {
      if (e.bookId == bookId) return e;
    }
    for (final list in _snapshot.booklists) {
      for (final e in list.books) {
        if (e.bookId == bookId) return e;
      }
    }
    return null;
  }

  /// Zip download (item 2): /zip/all packs every downloaded book;
  /// `/zip/booklist/<id>` packs that booklist's preview books that are
  /// on this phone. The zip is built in memory (archive's encoder
  /// is an in-memory operation) and returned as an attachment.
  Future<WebResponse> _zipRoute(List<String> s) async {
    List<int> indices;
    String zipName;
    if (s.length == 2 && s[1] == 'all') {
      indices = [for (var i = 0; i < _snapshot.files.length; i++) i];
      zipName = 'downloaded-books.zip';
    } else if (s.length == 3 && s[1] == 'booklist') {
      WebBooklist? found;
      for (final list in _snapshot.booklists) {
        if (list.id == s[2]) {
          found = list;
          break;
        }
      }
      if (found == null) return _notFound();
      indices = [
        for (final e in found.books)
          if (e.fileIndex != null) e.fileIndex!,
      ];
      zipName = '${found.name}.zip';
    } else {
      return _notFound();
    }
    if (indices.isEmpty) {
      return _html(
        HttpStatus.ok,
        _messagePage('这里还没有已下载的书，打包是空的。'),
      );
    }
    final archive = Archive();
    final usedNames = <String>{};
    for (final index in indices) {
      final file = await _fileFor(index);
      if (file == null) continue;
      final entry = _snapshot.files[index];
      final bytes = await file.readAsBytes();
      var name = _zipEntryName(entry);
      var n = 2;
      while (usedNames.contains(name)) {
        name = _zipEntryName(entry, suffix: n);
        n++;
      }
      usedNames.add(name);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    if (archive.files.isEmpty) {
      return _html(
        HttpStatus.ok,
        _messagePage('这里还没有已下载的书，打包是空的。'),
      );
    }
    final encoded = ZipEncoder().encode(archive);
    final body = Uint8List.fromList(encoded);
    return WebResponse(
      status: HttpStatus.ok,
      headers: <String, String>{
        'Content-Type': 'application/zip',
        'Content-Length': body.length.toString(),
        'Content-Disposition': _contentDisposition(zipName),
      },
      body: body,
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
      '.name a{color:#222;text-decoration:none}'
      '.name a:hover{text-decoration:underline}'
      '.meta{color:#666;font-size:0.9em}'
      '.desc{color:#555;font-size:0.9em;margin-top:0.3em;display:-webkit-box;'
      '-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}'
      '.actions{margin-top:0.4em}'
      '.actions a{display:inline-block;border:1px solid #888;border-radius:4px;'
      'padding:0.15em 0.8em;margin-right:0.5em;text-decoration:none;color:#222}'
      '.list-card{display:block;padding:0.6em 0;text-decoration:none;color:#222}'
      '.dim{color:#888}'
      '.detail{display:flex;gap:1.2em;align-items:flex-start}'
      '.cover-lg{width:180px;height:240px;flex:0 0 180px;object-fit:cover;background:#eee}'
      '.cover-lg-ph{width:180px;height:240px;flex:0 0 180px;background:#7a8699;color:#fff;'
      'display:flex;align-items:center;justify-content:center;font-size:4em}'
      '.detail .info{flex:1;min-width:0}'
      '.detail h1{font-size:1.3em;margin:0 0 0.4em}'
      '.detail .meta{margin:0.2em 0}'
      '.detail .desc-full{color:#333;margin-top:0.8em;white-space:pre-wrap}'
      '.zip-btn{display:inline-block;border:1px solid #888;border-radius:4px;'
      'padding:0.3em 1em;text-decoration:none;color:#222;margin:0.4em 0}'
      'a{color:#0645ad}'
      '@media (max-width:640px){.layout{display:block}.sidebar{width:auto}.detail{display:block}.cover-lg,.cover-lg-ph{margin-bottom:0.8em}}';

  String _page(String title, String body) =>
      '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<link rel="icon" type="image/png" href="/icon.png">'
      '<link rel="apple-touch-icon" href="/icon.png">'
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
  /// the left, title / author · format · size / description / actions
  /// on the right. The title opens the detail page. A downloaded
  /// book gets [Download] and, when it can be opened, [Read] —
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
    final title = escapeHtml(e.title);
    if (e.bookId != null) {
      b.write('<div class="name"><a href="/detail/${e.bookId}">$title</a></div>');
    } else {
      b.write('<div class="name">$title</div>');
    }
    final meta = [
      if (e.author.isNotEmpty) e.author,
      if (e.extension.isNotEmpty) e.extension.toUpperCase(),
      if (e.sizeLabel != null && e.sizeLabel!.isNotEmpty) e.sizeLabel!,
    ].join(' • ');
    if (meta.isNotEmpty) {
      b.write('<div class="meta">${escapeHtml(meta)}</div>');
    }
    final desc = e.description;
    if (desc != null && desc.trim().isNotEmpty) {
      b.write(
        '<div class="desc">${escapeHtml(truncateDescription(desc.trim()))}</div>',
      );
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

  /// One booklist card: its name and how many of its preview books
  /// are already on this phone. Borderless, like the book cards.
  String _booklistCard(WebBooklist l) {
    final downloaded = [
      for (final e in l.books)
        if (e.fileIndex != null) e,
    ].length;
    final count = l.count;
    final meta = count != null
        ? '已下载 $downloaded / 共 $count 本'
        : '已下载 $downloaded 本';
    return '<a class="list-card" href="/booklist/${Uri.encodeComponent(l.id)}">'
        '<div class="name">${escapeHtml(l.name)}</div>'
        '<div class="meta">${escapeHtml(meta)}</div>'
        '</a>';
  }

  String _grid(Iterable<String> cards) => cards.isEmpty
      ? '<p class="dim">${escapeHtml(_strings.empty)}</p>'
      : '<div class="grid">${cards.join()}</div>';

  String _homePage() {
    final downloaded = [
      for (var i = 0; i < _snapshot.files.length; i++) _bookCard(_entryFromFile(i)),
    ];
    final library = _snapshot.library.map(_bookCard);
    final lists = _snapshot.booklists.map(_booklistCard);
    final packAll = downloaded.isEmpty
        ? ''
        : ' <a class="zip-btn" href="/zip/all">全部打包</a>';
    return _page(
      _strings.homeTitle,
      _layout(
        '<h2 id="downloaded">${escapeHtml(_strings.downloadedSection)} (${downloaded.length})</h2>'
        '$packAll'
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

  /// A booklist page (item 6): [entries] are this page's books —
  /// live-fetched when available, else the snapshot's preview books.
  /// [page]/[hasMore] drive the prev/next links; [loadFailed] adds
  /// the fallback notice. A "pack download" button appears when the
  /// list has downloaded books on this phone.
  String _booklistPage(
    WebBooklist list,
    List<WebEntry> entries, {
    required int page,
    required bool hasMore,
    required bool loadFailed,
    bool isPreview = true,
  }) {
    final link = list.url.startsWith('http')
        ? '<p><a href="${escapeHtml(list.url)}">'
              '${escapeHtml(_strings.officialLink)}</a></p>'
        : '';
    final hasDownloaded = entries.any((e) => e.fileIndex != null);
    final pack = hasDownloaded
        ? '<a class="zip-btn" href="/zip/booklist/${Uri.encodeComponent(list.id)}">打包下载</a>'
        : '';
    final note = loadFailed
        ? '<p class="dim">加载失败，显示的是快照里的预览书。</p>'
        : isPreview
            ? '<p class="meta">${escapeHtml(_strings.previewNote)}</p>'
            : '';
    final nav = StringBuffer('<p>');
    if (page > 1) {
      nav.write(
        '<a href="/booklist/${Uri.encodeComponent(list.id)}?page=${page - 1}">上一页</a> ',
      );
    }
    nav.write('第 $page 页');
    if (hasMore) {
      nav.write(
        ' <a href="/booklist/${Uri.encodeComponent(list.id)}?page=${page + 1}">下一页</a>',
      );
    }
    nav.write('</p>');
    return _page(
      list.name,
      _layout(
        '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
        '<h1>${escapeHtml(list.name)}</h1>'
        '$note'
        '$pack'
        '${_grid(entries.map(_bookCard))}'
        '${nav.toString()}'
        '$link',
      ),
    );
  }

  /// The detail page (item 5): a large cover, the full synopsis,
  /// author / publisher / year / pages / language / format, and the
  /// download / read buttons — or, for a book that is not on this
  /// phone, "not downloaded" plus the download-to-phone trigger.
  String _detailPage(WebEntry e) {
    final b = StringBuffer('<div class="detail">');
    final cover = e.coverUrl;
    if (cover != null && cover.isNotEmpty) {
      b.write(
        '<img class="cover-lg" src="${escapeHtml(cover)}" loading="lazy" '
        'alt="${escapeHtml(e.title)}">',
      );
    } else {
      b.write(
        '<div class="cover-lg-ph" aria-hidden="true">'
        '${escapeHtml(_firstChar(e.title))}</div>',
      );
    }
    b.write('<div class="info">');
    b.write('<h1>${escapeHtml(e.title)}</h1>');
    final metaLines = <String>[
      if (e.author.isNotEmpty) '作者：${e.author}',
      if (e.publisher != null && e.publisher!.isNotEmpty)
        '出版社：${e.publisher!}',
      if (e.year != null) '出版年份：${e.year}',
      if (e.pages != null) '页数：${e.pages}',
      if (e.language != null && e.language!.isNotEmpty) '语言：${e.language!}',
      if (e.extension.isNotEmpty) '格式：${e.extension.toUpperCase()}',
      if (e.sizeLabel != null && e.sizeLabel!.isNotEmpty)
        '大小：${e.sizeLabel!}',
    ];
    for (final line in metaLines) {
      b.write('<div class="meta">${escapeHtml(line)}</div>');
    }
    final desc = e.description;
    if (desc != null && desc.trim().isNotEmpty) {
      b.write(
        '<div class="desc-full">${escapeHtml(desc.trim())}</div>',
      );
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
    b.write('</div></div>');
    return _page(
      e.title,
      _layout(
        '<p><a href="/">${escapeHtml(_strings.backHome)}</a></p>'
        '${b.toString()}',
      ),
    );
  }
}
