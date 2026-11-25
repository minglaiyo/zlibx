// The LAN web service: a process-wide HTTP server (dart:io only, no
// framework) that lets other devices on the same hotspot / Wi-Fi
//   * download the books on this phone from a plain-HTML home page
//     (no JavaScript, so e-readers and weak browsers work), and
//   * read shelf books in the user's own desktop browser through the
//     vendored foliate-js reader (/read, /book, /reader-assets).
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
  /// start again to refresh it). Binds [preferredPort] and, only if
  /// that fails, a system-chosen port.
  Future<int> start({
    required WebSnapshot snapshot,
    WebPageStrings strings = WebPageStrings.english,
    int preferredPort = kWebServicePort,
  }) async {
    final running = _server;
    if (running != null) return running.port;

    _snapshot = snapshot;
    _strings = strings;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // Preferred port taken by another program: any free port.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(_dispatch, onError: (Object e) => logIgnored('web_service', e));
    notifyListeners();
    return server.port;
  }

  /// Stop serving. Called ONLY from the Stop button.
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await server.close(force: true);
    notifyListeners();
  }

  // ── Routing ──────────────────────────────────────────────────────

  Future<void> _dispatch(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _plain(request, HttpStatus.methodNotAllowed, 'Method Not Allowed');
        return;
      }
      final segments = request.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.isEmpty) {
        await _html(request, HttpStatus.ok, _homePage());
        return;
      }
      switch (segments.first) {
        case 'booklist':
          await _booklistRoute(request, segments);
        case 'download':
          await _downloadRoute(request, segments);
        case 'read':
          await _readRoute(request, segments);
        case 'book':
          await _bookRoute(request, segments);
        case 'reader-assets':
          await _assetRoute(request, segments);
        default:
          await _notFound(request);
      }
    } catch (error) {
      logIgnored('web_service', error);
      try {
        await _plain(
          request,
          HttpStatus.internalServerError,
          'Internal Server Error',
        );
      } catch (_) {
        // Response already started / closed: nothing more to do.
      }
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

  Future<void> _notFound(HttpRequest request) =>
      _html(request, HttpStatus.notFound, _messagePage(_strings.notFound));

  Future<void> _booklistRoute(HttpRequest request, List<String> s) async {
    if (s.length != 2) return _notFound(request);
    for (final list in _snapshot.booklists) {
      if (list.id == s[1]) {
        return _html(request, HttpStatus.ok, _booklistPage(list));
      }
    }
    return _notFound(request);
  }

  Future<File?> _fileFor(int index) async {
    final path = await _resolvePath(_snapshot.files[index].location);
    if (path == null) return null;
    final file = File(path);
    return await file.exists() ? file : null;
  }

  Future<void> _downloadRoute(HttpRequest request, List<String> s) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound(request);
    final file = await _fileFor(index);
    if (file == null) return _notFound(request);
    await _sendFile(
      request,
      file,
      contentType: _mimeFor(_snapshot.files[index].extension),
      downloadName: p.basename(file.path),
    );
  }

  Future<void> _readRoute(HttpRequest request, List<String> s) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound(request);
    final entry = _snapshot.files[index];
    if (!isReadableExtension(entry.extension)) return _notFound(request);
    final file = await _fileFor(index);
    if (file == null) return _notFound(request);

    if (entry.extension.toLowerCase() == 'txt') {
      // Convert up front so a failure becomes a readable page here
      // rather than a broken reader; /book then hits the cache.
      try {
        await _txt.epubFor(file.path, title: entry.title);
      } on TxtConvertException {
        return _html(
          request,
          HttpStatus.unprocessableEntity,
          _messagePage(_strings.convertFailed),
        );
      }
    }
    await _html(
      request,
      HttpStatus.ok,
      buildReaderPage(
        index: index,
        title: entry.title,
        bookKey: fnv1a64Hex(entry.location),
      ),
    );
  }

  Future<void> _bookRoute(HttpRequest request, List<String> s) async {
    final index = _fileIndex(s);
    if (index == null) return _notFound(request);
    final entry = _snapshot.files[index];
    if (!isReadableExtension(entry.extension)) return _notFound(request);
    final file = await _fileFor(index);
    if (file == null) return _notFound(request);

    final ext = entry.extension.toLowerCase();
    if (ext == 'txt') {
      final Uint8List epub;
      try {
        epub = await _txt.epubFor(file.path, title: entry.title);
      } on TxtConvertException {
        return _plain(request, HttpStatus.unprocessableEntity, 'convert failed');
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'epub+zip')
        ..headers.set('X-Book-Name', 'book.epub')
        ..headers.contentLength = epub.length;
      if (request.method != 'HEAD') request.response.add(epub);
      await request.response.close();
      return;
    }
    request.response.headers.set('X-Book-Name', 'book.$ext');
    await _sendFile(request, file, contentType: _mimeFor(ext));
  }

  Future<void> _assetRoute(HttpRequest request, List<String> s) async {
    final name = s.sublist(1).join('/');
    if (!kReaderAssetWhitelist.contains(name)) return _notFound(request);
    final bytes = await _loadAsset('assets/web-reader/$name');
    if (bytes == null) return _notFound(request);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'text',
        'javascript',
        charset: 'utf-8',
      )
      ..headers.contentLength = bytes.length;
    if (request.method != 'HEAD') request.response.add(bytes);
    await request.response.close();
  }

  // ── Responses ────────────────────────────────────────────────────

  Future<void> _html(HttpRequest request, int status, String body) async {
    final bytes = utf8.encode(body);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.contentLength = bytes.length;
    if (request.method != 'HEAD') request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _plain(HttpRequest request, int status, String body) async {
    final bytes = utf8.encode(body);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..headers.contentLength = bytes.length;
    if (request.method != 'HEAD') request.response.add(bytes);
    await request.response.close();
  }

  /// Stream [file] straight from disk (never copied to a cache first).
  /// Supports a single `Range: bytes=a-b` so interrupted downloads can
  /// resume.
  Future<void> _sendFile(
    HttpRequest request,
    File file, {
    required ContentType contentType,
    String? downloadName,
  }) async {
    final length = await file.length();
    var start = 0;
    var end = length - 1;
    var status = HttpStatus.ok;

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
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
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
          await request.response.close();
          return;
        }
        status = HttpStatus.partialContent;
      }
    }

    final count = length == 0 ? 0 : end - start + 1;
    final response = request.response
      ..statusCode = status
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentLength = count;
    if (status == HttpStatus.partialContent) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    if (downloadName != null) {
      response.headers.set(
        HttpHeaders.contentDispositionHeader,
        _contentDisposition(downloadName),
      );
    }
    if (request.method != 'HEAD' && count > 0) {
      await response.addStream(file.openRead(start, end + 1));
    }
    await response.close();
  }

  static String _contentDisposition(String name) {
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7E]'), '_').replaceAll(
      RegExp(r'["\\]'),
      '_',
    );
    return 'attachment; filename="$ascii"; '
        "filename*=UTF-8''${Uri.encodeComponent(name)}";
  }

  static ContentType _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'epub':
        return ContentType('application', 'epub+zip');
      case 'pdf':
        return ContentType('application', 'pdf');
      case 'mobi':
        return ContentType('application', 'x-mobipocket-ebook');
      case 'azw3':
      case 'azw':
        return ContentType('application', 'vnd.amazon.ebook');
      case 'fb2':
        return ContentType('application', 'x-fictionbook+xml');
      case 'cbz':
        return ContentType('application', 'vnd.comicbook+zip');
      case 'txt':
        return ContentType('text', 'plain', charset: 'utf-8');
      default:
        return ContentType('application', 'octet-stream');
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
