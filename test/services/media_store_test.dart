// Unit tests for MediaStoreFiles.
//
// The pure helpers (mimeTypeForExtension, isContentUri) and the
// plain-path branches (exists / delete / shareablePath) run without
// any platform. The content:// branches are Android-gated, so those
// tests enable the @visibleForTesting seam (forceAndroidForTesting)
// and stub the 'zlibx/media_store' channel with an in-memory fake.
// `open` is NOT tested: it launches an external app.
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:zlibx/services/media_store.dart';

/// Minimal in-memory stand-in for the Kotlin MediaStore side.
class _FakeMediaStore {
  final Map<String, List<int>> entries = <String, List<int>>{};
  final Map<String, String> realPaths = <String, String>{};
  int _nextId = 0;

  Future<dynamic> handle(MethodCall call) async {
    final args = call.arguments as Map? ?? <String, Object>{};
    switch (call.method) {
      case 'publishToDownloads':
        final uri = 'content://media/external/downloads/${_nextId++}';
        entries[uri] = <int>[];
        return uri;
      case 'createPendingDownload':
        final uri = 'content://media/external/downloads/${_nextId++}';
        entries[uri] = <int>[];
        return uri;
      case 'writePendingChunk':
        final uri = args['uri'] as String;
        final entry = entries[uri];
        if (entry == null) return false;
        entry.addAll(args['bytes'] as Uint8List);
        return true;
      case 'finishPendingDownload':
        return entries.containsKey(args['uri'] as String);
      case 'abortPendingDownload':
        entries.remove(args['uri'] as String);
        return true;
      case 'pendingEntrySize':
        final entry = entries[args['uri'] as String];
        return entry == null ? -1 : entry.length;
      case 'contentExists':
        return entries.containsKey(args['uri'] as String);
      case 'deleteContent':
        return entries.remove(args['uri'] as String) != null;
      case 'copyContentToCache':
        return '/cache/copied.epub';
      case 'realPathForContent':
        return realPaths[args['uri'] as String];
      default:
        return null;
    }
  }
}

void main() {
  const channel = MethodChannel('zlibx/media_store');
  late Directory tempDir;
  late _FakeMediaStore fake;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('media_store_');
    fake = _FakeMediaStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fake.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    MediaStoreFiles.forceAndroidForTesting = false;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('mimeTypeForExtension', () {
    test('maps known book extensions', () {
      expect(MediaStoreFiles.mimeTypeForExtension('epub'),
          'application/epub+zip');
      expect(
          MediaStoreFiles.mimeTypeForExtension('pdf'), 'application/pdf');
      expect(MediaStoreFiles.mimeTypeForExtension('mobi'),
          'application/x-mobipocket-ebook');
      expect(MediaStoreFiles.mimeTypeForExtension('azw3'),
          'application/vnd.amazon.ebook');
      expect(MediaStoreFiles.mimeTypeForExtension('azw'),
          'application/vnd.amazon.mobi8-ebook');
      expect(MediaStoreFiles.mimeTypeForExtension('fb2'),
          'application/x-fictionbook+xml');
      expect(MediaStoreFiles.mimeTypeForExtension('cbz'), 'application/x-cbz');
      expect(MediaStoreFiles.mimeTypeForExtension('cbr'), 'application/x-cbr');
      expect(MediaStoreFiles.mimeTypeForExtension('txt'), 'text/plain');
      // P3-3: formats the app also opens (magic table / LibGen):
      // djvu/djv share one MIME, the office formats keep their own.
      expect(MediaStoreFiles.mimeTypeForExtension('djvu'), 'image/vnd.djvu');
      expect(MediaStoreFiles.mimeTypeForExtension('djv'), 'image/vnd.djvu');
      expect(MediaStoreFiles.mimeTypeForExtension('docx'),
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
      expect(
          MediaStoreFiles.mimeTypeForExtension('doc'), 'application/msword');
      expect(MediaStoreFiles.mimeTypeForExtension('rtf'), 'application/rtf');
      expect(MediaStoreFiles.mimeTypeForExtension('zip'), 'application/zip');
      expect(MediaStoreFiles.mimeTypeForExtension('chm'),
          'application/vnd.ms-htmlhelp');
      expect(MediaStoreFiles.mimeTypeForExtension('lit'),
          'application/x-ms-reader');
    });

    test('mimeTypeForPath takes the extension from the path', () {
      expect(MediaStoreFiles.mimeTypeForPath('/sdcard/Book - 123.epub'),
          'application/epub+zip');
      expect(MediaStoreFiles.mimeTypeForPath('/sdcard/Book.FB2'),
          'application/x-fictionbook+xml');
      expect(MediaStoreFiles.mimeTypeForPath('/sdcard/noext'),
          'application/octet-stream');
    });

    test('is case-insensitive and defaults unknown / null', () {
      expect(
          MediaStoreFiles.mimeTypeForExtension('PDF'), 'application/pdf');
      expect(MediaStoreFiles.mimeTypeForExtension('xyz'),
          'application/octet-stream');
      expect(MediaStoreFiles.mimeTypeForExtension(null),
          'application/octet-stream');
      expect(MediaStoreFiles.mimeTypeForExtension(''),
          'application/octet-stream');
    });
  });

  group('isContentUri', () {
    test('only content:// counts', () {
      expect(MediaStoreFiles.isContentUri('content://media/1'), isTrue);
      expect(MediaStoreFiles.isContentUri('/sdcard/book.epub'), isFalse);
      expect(MediaStoreFiles.isContentUri('file:///sdcard/book.epub'),
          isFalse);
      expect(MediaStoreFiles.isContentUri(''), isFalse);
    });
  });

  group('plain paths (no platform)', () {
    test('exists reflects the real file', () async {
      final file = File('${tempDir.path}/book.epub');
      expect(await MediaStoreFiles.exists(file.path), isFalse);
      await file.writeAsBytes(<int>[1, 2, 3]);
      expect(await MediaStoreFiles.exists(file.path), isTrue);
    });

    test('delete removes a real file and is false when missing', () async {
      final file = File('${tempDir.path}/book.epub');
      expect(await MediaStoreFiles.delete(file.path), isFalse);
      await file.writeAsBytes(<int>[1, 2, 3]);
      expect(await MediaStoreFiles.delete(file.path), isTrue);
      expect(await file.exists(), isFalse);
    });

    test('shareablePath passes plain paths through unchanged off Android',
        () async {
      const path = '/sdcard/Download/zlibx/book.epub';
      expect(await MediaStoreFiles.shareablePath(path), path);
    });
  });

  group('Android-gated methods without the seam', () {
    test('publish and create return null on non-Android', () async {
      expect(
        await MediaStoreFiles.publishToDownloads(
          sourcePath: '${tempDir.path}/book.epub',
          displayName: 'book.epub',
          mimeType: 'application/epub+zip',
        ),
        isNull,
      );
      expect(
        await MediaStoreFiles.createPendingDownload(
          displayName: 'book.epub',
          mimeType: 'application/epub+zip',
        ),
        isNull,
      );
    });

    test('write / finish / abort / size fail closed on non-Android',
        () async {
      const uri = 'content://media/external/downloads/1';
      expect(await MediaStoreFiles.writePendingChunk(uri, <int>[1]), isFalse);
      expect(await MediaStoreFiles.finishPendingDownload(uri), isFalse);
      expect(await MediaStoreFiles.abortPendingDownload(uri), isFalse);
      expect(await MediaStoreFiles.pendingEntrySize(uri), -1);
      expect(await MediaStoreFiles.exists(uri), isFalse);
      expect(await MediaStoreFiles.delete(uri), isFalse);
      expect(await MediaStoreFiles.shareablePath(uri), isNull);
    });
  });

  group('content URIs through the stubbed channel', () {
    setUp(() {
      MediaStoreFiles.forceAndroidForTesting = true;
    });

    test('publish / create / write / size / finish round trip', () async {
      final published = await MediaStoreFiles.publishToDownloads(
        sourcePath: '${tempDir.path}/book.epub',
        displayName: 'book.epub',
        mimeType: 'application/epub+zip',
      );
      expect(published, startsWith('content://media/external/downloads/'));

      final uri = await MediaStoreFiles.createPendingDownload(
        displayName: 'book2.epub',
        mimeType: 'application/epub+zip',
      );
      expect(uri, isNotNull);
      expect(await MediaStoreFiles.pendingEntrySize(uri!), 0);
      expect(await MediaStoreFiles.writePendingChunk(uri, <int>[1, 2, 3]),
          isTrue);
      expect(await MediaStoreFiles.pendingEntrySize(uri), 3);
      expect(await MediaStoreFiles.finishPendingDownload(uri), isTrue);
    });

    test('abort removes the entry; later writes fail', () async {
      final uri = (await MediaStoreFiles.createPendingDownload(
        displayName: 'book.epub',
        mimeType: 'application/epub+zip',
      ))!;
      expect(await MediaStoreFiles.abortPendingDownload(uri), isTrue);
      expect(await MediaStoreFiles.pendingEntrySize(uri), -1);
      expect(await MediaStoreFiles.writePendingChunk(uri, <int>[1]), isFalse);
    });

    test('exists / delete route to the channel for content URIs', () async {
      final uri = (await MediaStoreFiles.createPendingDownload(
        displayName: 'book.epub',
        mimeType: 'application/epub+zip',
      ))!;
      expect(await MediaStoreFiles.exists(uri), isTrue);
      expect(await MediaStoreFiles.exists(
          'content://media/external/downloads/999'),
          isFalse);
      expect(await MediaStoreFiles.delete(uri), isTrue);
      expect(await MediaStoreFiles.exists(uri), isFalse);
      expect(await MediaStoreFiles.delete(uri), isFalse);
    });

    test('exists falls back to the real path when the URI will not open',
        () async {
      const uri = 'content://media/external/downloads/999';
      final file = File('${tempDir.path}/stale.epub')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      fake.realPaths[uri] = file.path;
      // The URI is not in entries, so contentExists says no — but the
      // file is still on disk at the resolved real path.
      expect(await MediaStoreFiles.exists(uri), isTrue);
      await file.delete();
      expect(await MediaStoreFiles.exists(uri), isFalse);
    });

    test('shareablePath copies a content URI to the cache', () async {
      final uri = (await MediaStoreFiles.createPendingDownload(
        displayName: 'book.epub',
        mimeType: 'application/epub+zip',
      ))!;
      expect(await MediaStoreFiles.shareablePath(uri), '/cache/copied.epub');
    });
  });

  group('shareablePath copies plain paths on Android', () {
    late Directory sourceDir;

    setUp(() {
      MediaStoreFiles.forceAndroidForTesting = true;
      MediaStoreFiles.shareCacheDirForTesting = tempDir;
      sourceDir = Directory.systemTemp.createTempSync('media_store_src_');
    });

    tearDown(() {
      MediaStoreFiles.shareCacheDirForTesting = null;
      if (sourceDir.existsSync()) sourceDir.deleteSync(recursive: true);
    });

    test('copies a real file outside the cache into the cache', () async {
      final source = File(p.join(
        sourceDir.path,
        'Bird (DK Eyewitness Books) - 1114478.pdf',
      ))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final shared = await MediaStoreFiles.shareablePath(source.path);
      expect(shared,
          p.join(tempDir.path, 'share_Bird (DK Eyewitness Books) - 1114478.pdf'));
      expect(File(shared!).readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(await source.exists(), isTrue);
    });

    test('returns a path already in the cache unchanged', () async {
      final file = File(p.join(tempDir.path, 'already.epub'))
        ..writeAsBytesSync(<int>[9]);
      expect(await MediaStoreFiles.shareablePath(file.path), file.path);
      expect(
        tempDir.listSync().map((e) => e.path).toList(),
        <String>[file.path],
      );
    });

    test('returns null for a missing plain file', () async {
      expect(
        await MediaStoreFiles.shareablePath(p.join(sourceDir.path, 'gone.epub')),
        isNull,
      );
    });

    test('truncates a long CJK stem to 120 UTF-8 bytes', () async {
      final name = '${'黎' * 50} - 123.epub';
      final source = File(p.join(sourceDir.path, name))
        ..writeAsBytesSync(<int>[7]);
      final shared = await MediaStoreFiles.shareablePath(source.path);
      expect(shared, p.join(tempDir.path, 'share_${'黎' * 40}.epub'));
      expect(File(shared!).readAsBytesSync(), <int>[7]);
    });
  });
}
