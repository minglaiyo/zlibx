// Loopback HTTP server that feeds one local book to the in-app
// reader's WebView.
//
// Why a server instead of file://: the WebView cannot reliably fetch
// a local EPUB (and its foliate-js assets) from file:// —
// cross-origin and sandbox rules differ per platform. Serving
// everything from one loopback origin (127.0.0.1, random port) makes
// the page, the foliate assets and the book same-origin, exactly
// like the web reader's /read + /reader-assets + /book split.
//
// The server is deliberately minimal and short-lived: it only serves
// the one book this reader instance opened, only on loopback, and it
// stops when the reader page closes. It is NOT the LAN web service —
// it runs even when that service is off, and nothing outside this
// device can reach it (loopback only, no LAN bind).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'local_reader_page.dart';
import 'reader_formats.dart';
import 'txt_to_epub.dart';

/// Serves one book + the reader page to a single WebView.
class LocalReaderServer {
  /// Real path of the book file on disk.
  final String filePath;

  /// Title shown in the reader page.
  final String title;

  /// Stable per-book key (the download task id) for progress.
  final String bookKey;

  /// Position restored from Hive (null on first open).
  final String? savedCfi;

  final TxtToEpub _txt;

  /// Loads a foliate asset by bundle path; injectable so tests do
  /// not depend on the real asset bundle (same pattern as the web
  /// service's assetLoader).
  final Future<List<int>?> Function(String assetPath) _assetLoader;

  HttpServer? _server;

  LocalReaderServer({
    required this.filePath,
    required this.title,
    required this.bookKey,
    this.savedCfi,
    TxtToEpub? txt,
    Future<List<int>?> Function(String assetPath)? assetLoader,
  }) : _txt = txt ?? TxtToEpub(),
       _assetLoader = assetLoader ?? _bundleAsset;

  static Future<List<int>?> _bundleAsset(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// The base URL the WebView loads (e.g. http://127.0.0.1:54321/).
  Uri get baseUrl {
    final server = _server;
    if (server == null) throw StateError('LocalReaderServer not started');
    return Uri.parse('http://127.0.0.1:${server.port}/');
  }

  bool get isRunning => _server != null;

  /// Bind loopback on a random port and start serving. Only GET is
  /// served; everything else is a 404/405.
  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
    return baseUrl;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      unawaited(_handle(req).catchError((Object _) {}));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'GET') {
        req.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write('method not allowed');
        await req.response.close();
        return;
      }
      final segments = req.uri.pathSegments;
      if (segments.isEmpty) {
        await _sendHtml(req, buildLocalReaderPage(
          title: title,
          bookKey: bookKey,
          savedCfi: savedCfi,
        ));
        return;
      }
      if (segments.first == 'assets' && segments.length == 2) {
        await _sendAsset(req, segments[1]);
        return;
      }
      // vendor/ is one more segment: /assets/vendor/zip.js.
      if (segments.first == 'assets' &&
          segments.length == 3 &&
          segments[1] == 'vendor') {
        await _sendAsset(req, 'vendor/${segments[2]}');
        return;
      }
      if (segments.length == 1 && segments.first == 'book') {
        await _sendBook(req);
        return;
      }
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('not found');
      await req.response.close();
    } catch (_) {
      // A handler failure must not kill the server loop.
      try {
        req.response
          ..statusCode = HttpStatus.internalServerError
          ..write('error');
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _sendHtml(HttpRequest req, String html) async {
    final bytes = utf8.encode(html);
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.contentLengthHeader, bytes.length)
      ..add(bytes);
    await req.response.close();
  }

  Future<void> _sendAsset(HttpRequest req, String name) async {
    if (!kReaderAssetWhitelist.contains(name)) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('not found');
      await req.response.close();
      return;
    }
    final bytes = await _assetLoader('assets/web-reader/$name');
    if (bytes == null) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('not found');
      await req.response.close();
      return;
    }
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'javascript')
      ..headers.set(HttpHeaders.contentLengthHeader, bytes.length)
      ..add(bytes);
    await req.response.close();
  }

  Future<void> _sendBook(HttpRequest req) async {
    final file = File(filePath);
    if (!await file.exists()) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('book not found');
      await req.response.close();
      return;
    }
    final ext = p.extension(filePath).replaceFirst('.', '').toLowerCase();
    if (ext == 'txt') {
      // TXT is converted to EPUB up front (cached on disk by
      // TxtToEpub), so a conversion failure is a readable error here
      // rather than a broken reader page.
      final Uint8List epub;
      try {
        epub = await _txt.epubFor(filePath, title: title);
      } on TxtConvertException {
        req.response
          ..statusCode = HttpStatus.unprocessableEntity
          ..write('convert failed');
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'epub+zip')
        ..headers.set('X-Book-Name', 'book.epub')
        ..headers.set(HttpHeaders.contentLengthHeader, epub.length)
        ..add(epub);
      await req.response.close();
      return;
    }
    final bytes = await file.readAsBytes();
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(_mimeFor(ext))
      ..headers.set('X-Book-Name', p.basename(filePath))
      ..headers.set(HttpHeaders.contentLengthHeader, bytes.length)
      ..add(bytes);
    await req.response.close();
  }

  static String _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'epub':
        return 'application/epub+zip';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw3':
      case 'azw':
        return 'application/vnd.amazon.ebook';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'cbz':
        return 'application/vnd.comicbook+zip';
      default:
        return 'application/octet-stream';
    }
  }
}
