// Tests for the pending-URI direct-write path (PendingUriWriter +
// the MediaStoreFiles channel calls it drives). This is the DEFAULT
// download path since minSdk 29, and it had zero test coverage.
//
// The platform channel is stubbed with an in-memory fake MediaStore
// (entries are just byte lists keyed by URI). MediaStoreFiles is
// Android-gated, so the tests enable its @visibleForTesting seam
// (forceAndroidForTesting) and reset it in tearDown; production
// behaviour is unchanged.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:zlibx/services/media_store.dart';
import 'package:zlibx/services/pending_uri_writer.dart';

/// In-memory stand-in for the Kotlin MediaStore side: entries are
/// byte lists keyed by content URI. Flags let tests fail one call.
class _FakeMediaStore {
  final Map<String, List<int>> entries = <String, List<int>>{};
  final List<Uint8List> writtenChunks = <Uint8List>[];
  final List<String> finishedUris = <String>[];
  int _nextId = 0;

  /// Fail the next createPendingDownload call only, then recover.
  bool failNextCreate = false;

  /// Every writePendingChunk call returns false.
  bool failWrite = false;

  /// Every finishPendingDownload call returns false.
  bool failFinish = false;

  /// pendingEntrySize returns -1 (entry unknown).
  bool failSize = false;

  Future<dynamic> handle(MethodCall call) async {
    final args = call.arguments as Map? ?? <String, Object>{};
    switch (call.method) {
      case 'createPendingDownload':
        if (failNextCreate) {
          failNextCreate = false;
          return null;
        }
        final uri = 'content://media/external/downloads/${_nextId++}';
        entries[uri] = <int>[];
        return uri;
      case 'writePendingChunk':
        final uri = args['uri'] as String;
        final bytes = args['bytes'] as Uint8List;
        if (failWrite) return false;
        final entry = entries[uri];
        if (entry == null) return false;
        entry.addAll(bytes);
        writtenChunks.add(bytes);
        return true;
      case 'finishPendingDownload':
        if (failFinish) return false;
        final uri = args['uri'] as String;
        finishedUris.add(uri);
        return entries.containsKey(uri);
      case 'abortPendingDownload':
        entries.remove(args['uri'] as String);
        return true;
      case 'pendingEntrySize':
        if (failSize) return -1;
        final entry = entries[args['uri'] as String];
        return entry == null ? -1 : entry.length;
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
    tempDir = Directory.systemTemp.createTempSync('pending_uri_writer_');
    fake = _FakeMediaStore();
    MediaStoreFiles.forceAndroidForTesting = true;
    PendingUriWriter.resetPersistenceStats();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fake.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    MediaStoreFiles.forceAndroidForTesting = false;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String savePath(String name) => p.join(tempDir.path, name);
  String statePath(String path) => PendingUriWriter.statePathFor(path);

  Future<Map<String, dynamic>> readSidecar(String path) async {
    final raw = await File(statePath(path)).readAsString();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  group('persistence metrics', () {
    test('counts successful sidecar writes and latency buckets', () async {
      final path = savePath('Metrics - 1.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Metrics - 1.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      await writer.flush();

      final stats = PendingUriWriter.persistenceStats;
      expect(stats.calls, 2);
      expect(stats.successes, 2);
      expect(stats.failures, 0);
      expect(stats.directRenames + stats.fallbackSuccesses, 2);
      expect(
        stats.renameFallbacks,
        stats.fallbackSuccesses + stats.fallbackFailures,
      );
      expect(stats.latencyBuckets.fold<int>(0, (sum, n) => sum + n), 2);
      expect(
        stats.totalMicroseconds,
        greaterThanOrEqualTo(stats.maxMicroseconds),
      );
    });

    test(
      'counts a sidecar persistence failure without failing the writer',
      () async {
        final path = savePath('Metrics - 2.epub.part');
        await Directory(statePath(path)).create();
        final writer = await PendingUriWriter.create(
          displayName: 'Metrics - 2.epub',
          mimeType: 'application/epub+zip',
          savePath: path,
        );

        expect(writer, isNotNull);
        final stats = PendingUriWriter.persistenceStats;
        expect(stats.calls, 1);
        expect(stats.successes, 0);
        expect(stats.failures, 1);
        expect(stats.renameFallbacks, 1);
        expect(stats.fallbackFailures, 1);
        expect(stats.latencyBuckets.fold<int>(0, (sum, n) => sum + n), 1);
        await writer!.discard();
      },
    );
  });

  group('create', () {
    test('writes a sidecar with the new URI and zero bytes', () async {
      final path = savePath('Book - 1.epub.part');
      final writer = await PendingUriWriter.create(
        displayName: 'Book - 1.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      );
      expect(writer, isNotNull);
      expect(writer!.uri, startsWith('content://media/external/downloads/'));
      expect(writer.bytesWritten, 0);
      expect(writer.committedBytes, 0);
      final sidecar = await readSidecar(path);
      expect(sidecar['uri'], writer.uri);
      expect(sidecar['bytesWritten'], 0);
      expect(await File('${statePath(path)}.tmp').exists(), isFalse);
    });

    test('returns null and writes no sidecar when creation fails', () async {
      fake.failNextCreate = true;
      final path = savePath('Book - 2.epub.part');
      final writer = await PendingUriWriter.create(
        displayName: 'Book - 2.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      );
      expect(writer, isNull);
      expect(await File(statePath(path)).exists(), isFalse);
    });
  });

  group('add / flush', () {
    test('small adds only buffer; flush writes and updates the sidecar',
        () async {
      final path = savePath('Book - 3.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 3.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      final chunk = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      await writer.add(chunk);
      expect(writer.bytesWritten, 5);
      expect(writer.committedBytes, 0);
      expect(fake.writtenChunks, isEmpty);
      expect((await readSidecar(path))['bytesWritten'], 0);
      await writer.flush();
      expect(writer.committedBytes, 5);
      expect(fake.entries[writer.uri], <int>[1, 2, 3, 4, 5]);
      expect((await readSidecar(path))['bytesWritten'], 5);
    });

    test('a chunk over 1 MB is queued as one batch and flush commits it',
        () async {
      final path = savePath('Book - 4.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 4.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      final chunk = Uint8List(1024 * 1024 + 100);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = i % 251;
      }
      await writer.add(chunk);
      expect(writer.bytesWritten, chunk.length);
      await writer.flush();
      expect(writer.committedBytes, chunk.length);
      expect(fake.writtenChunks, hasLength(1));
      expect(fake.entries[writer.uri]!.length, chunk.length);
      expect((await readSidecar(path))['bytesWritten'], chunk.length);
    });

    test('mutating the caller chunk after add() does not corrupt the write',
        () async {
      // Regression test for the GPT item-1 snapshot (036e8ca6):
      // add() must copy the chunk — callers reuse their network
      // buffer as soon as add() returns.
      final path = savePath('Book - 5.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 5.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      final chunk = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      await writer.add(chunk);
      chunk.fillRange(0, chunk.length, 0);
      await writer.flush();
      expect(fake.entries[writer.uri], <int>[1, 2, 3, 4, 5]);
    });

    test('a failed platform write surfaces as StateError and sticks',
        () async {
      final path = savePath('Book - 6.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 6.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      fake.failWrite = true;
      await writer.add(Uint8List.fromList(<int>[9, 9, 9]));
      await expectLater(writer.flush(), throwsStateError);
      expect(writer.committedBytes, 0);
      expect((await readSidecar(path))['bytesWritten'], 0);
      await expectLater(
        writer.add(Uint8List.fromList(<int>[1])),
        throwsStateError,
      );
    });

    test('bytesWritten counts committed + queued + buffered', () async {
      final path = savePath('Book - 7.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 7.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List(100));
      expect(writer.bytesWritten, 100);
      await writer.add(Uint8List(1024 * 1024));
      expect(writer.bytesWritten, 1024 * 1024 + 100);
      await writer.flush();
      expect(writer.bytesWritten, 1024 * 1024 + 100);
      expect(writer.committedBytes, 1024 * 1024 + 100);
    });

    test('add after close throws StateError', () async {
      final path = savePath('Book - 8.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 8.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.close();
      await expectLater(
        writer.add(Uint8List.fromList(<int>[1])),
        throwsStateError,
      );
    });
  });

  group('resume', () {
    test('returns null without a sidecar', () async {
      final writer = await PendingUriWriter.resume(
        savePath: savePath('Nope - 1.epub.part'),
      );
      expect(writer, isNull);
    });

    test('returns null for corrupt sidecars', () async {
      const badBodies = <String>[
        'not json at all',
        '{"uri": 123, "bytesWritten": 0}',
        '{"uri": "content://x/1", "bytesWritten": "100"}',
        '{"uri": "content://x/1", "bytesWritten": -5}',
        '{"uri": "", "bytesWritten": 0}',
        '{"uri": "content://x/1"}',
        '[1, 2, 3]',
      ];
      for (var i = 0; i < badBodies.length; i++) {
        final path = savePath('Bad - $i.epub.part');
        await File(statePath(path)).writeAsString(badBodies[i]);
        final writer = await PendingUriWriter.resume(savePath: path);
        expect(writer, isNull, reason: 'case $i: ${badBodies[i]}');
      }
    });

    test('restores the committed offset from a valid sidecar', () async {
      final path = savePath('Book - 9.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 9.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      final data = Uint8List(4096);
      await writer.add(data);
      await writer.flush();
      final resumed = await PendingUriWriter.resume(savePath: path);
      expect(resumed, isNotNull);
      expect(resumed!.uri, writer.uri);
      expect(resumed.committedBytes, 4096);
      expect(resumed.bytesWritten, 4096);
    });

    test('reconciles a lagging sidecar against the entry true size',
        () async {
      // B1: the process died after a chunk committed but before the
      // sidecar was written — the entry size wins and the sidecar is
      // updated, so resuming does not duplicate bytes.
      final path = savePath('Book - 10.epub.part');
      final uri = 'content://media/external/downloads/42';
      fake.entries[uri] = List<int>.filled(150, 7);
      await File(statePath(path)).writeAsString(
        jsonEncode(<String, Object>{'uri': uri, 'bytesWritten': 100}),
      );
      final resumed = await PendingUriWriter.resume(savePath: path);
      expect(resumed, isNotNull);
      expect(resumed!.committedBytes, 150);
      expect((await readSidecar(path))['bytesWritten'], 150);
    });

    test('keeps the sidecar value when the size query fails', () async {
      final path = savePath('Book - 11.epub.part');
      final uri = 'content://media/external/downloads/43';
      await File(statePath(path)).writeAsString(
        jsonEncode(<String, Object>{'uri': uri, 'bytesWritten': 100}),
      );
      // The entry exists with a different size, but the size query
      // itself fails (pendingEntrySize is -1): the sidecar value wins.
      fake.entries[uri] = List<int>.filled(150, 7);
      fake.failSize = true;
      final resumed = await PendingUriWriter.resume(savePath: path);
      expect(resumed, isNotNull);
      expect(resumed!.committedBytes, 100);
      expect((await readSidecar(path))['bytesWritten'], 100);
    });

    test('waits for the previous live writer queued batches', () async {
      // A retry builds a fresh writer while the failed attempt's
      // batches may still be landing; resume() settles them first so
      // the reconciled size is final.
      final path = savePath('Book - 12.epub.part');
      final first = (await PendingUriWriter.create(
        displayName: 'Book - 12.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await first.add(Uint8List(1024 * 1024 + 10));
      final resumed = await PendingUriWriter.resume(savePath: path);
      expect(resumed, isNotNull);
      expect(resumed!.committedBytes, 1024 * 1024 + 10);
    });
  });

  group('discard / reset / finish', () {
    test('discard deletes the entry and both sidecars', () async {
      final path = savePath('Book - 13.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 13.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      await writer.flush();
      await File('$path.meta').writeAsString('{}');
      await writer.discard();
      expect(fake.entries.containsKey(writer.uri), isFalse);
      expect(await File(statePath(path)).exists(), isFalse);
      expect(await File('$path.meta').exists(), isFalse);
    });

    test('reset recreates the entry empty and drops buffered bytes',
        () async {
      final path = savePath('Book - 14.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 14.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      final oldUri = writer.uri;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      expect(await writer.reset(), isTrue);
      expect(writer.uri, isNot(oldUri));
      expect(fake.entries.containsKey(oldUri), isFalse);
      expect(writer.bytesWritten, 0);
      expect(writer.committedBytes, 0);
      expect((await readSidecar(path))['uri'], writer.uri);
      expect((await readSidecar(path))['bytesWritten'], 0);
      // The pre-reset buffered bytes must not land in the new entry.
      await writer.add(Uint8List.fromList(<int>[4, 5]));
      await writer.flush();
      expect(fake.entries[writer.uri], <int>[4, 5]);
    });

    test('reset returns false when the platform cannot recreate', () async {
      final path = savePath('Book - 15.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 15.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      fake.failNextCreate = true;
      expect(await writer.reset(), isFalse);
      expect(writer.bytesWritten, 0);
      expect(writer.committedBytes, 0);
    });

    test('finish publishes and removes the sidecar and .meta', () async {
      final path = savePath('Book - 16.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 16.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      await writer.flush();
      await File('$path.meta').writeAsString('{}');
      expect(await writer.finish(), isTrue);
      expect(fake.finishedUris, <String>[writer.uri]);
      expect(await File(statePath(path)).exists(), isFalse);
      expect(await File('$path.meta').exists(), isFalse);
    });

    test('finish returns false on publish failure and keeps the sidecar',
        () async {
      final path = savePath('Book - 17.epub.part');
      final writer = (await PendingUriWriter.create(
        displayName: 'Book - 17.epub',
        mimeType: 'application/epub+zip',
        savePath: path,
      ))!;
      await writer.add(Uint8List.fromList(<int>[1, 2, 3]));
      await writer.flush();
      fake.failFinish = true;
      expect(await writer.finish(), isFalse);
      // The sidecar survives so a later retry can resume the entry.
      expect(await File(statePath(path)).exists(), isTrue);
      expect((await readSidecar(path))['bytesWritten'], 3);
    });
  });
}
