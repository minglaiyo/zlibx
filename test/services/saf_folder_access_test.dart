// Unit tests for SafFolderAccess.
//
// The SAF folder grant lets the app read books in Download/zlibx/
// that a clear-data orphaned (stat-able but not openable). The
// platform side is stubbed with an in-memory fake on the
// 'zlibx/media_store' channel; the file-identity checks (canOpen /
// readablePath pass-through) run against real temp files. Hive is
// never touched: the tree URI and tree root come from the
// @visibleForTesting seams.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlibx/services/saf_folder_access.dart';

const _kTreeUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADownload%2Fzlibx';

/// Minimal in-memory stand-in for the Kotlin SAF side.
class _FakeSaf {
  String? pickResult = _kTreeUri;
  List<String> persistedUris = <String>[];
  bool copyFails = false;
  bool deleteResult = true;
  late Directory cacheDir;

  final List<String> calls = <String>[];
  int copyCalls = 0;
  String? lastTreeUri;
  String? lastRelativePath;
  String? lastDeleteTreeUri;
  String? lastDeleteRelativePath;

  Future<dynamic> handle(MethodCall call) async {
    calls.add(call.method);
    final args = call.arguments as Map? ?? <String, Object>{};
    switch (call.method) {
      case 'pickDownloadTree':
        return pickResult;
      case 'copyTreeFileToCache':
        copyCalls++;
        lastTreeUri = args['treeUri'] as String?;
        lastRelativePath = args['relativePath'] as String?;
        if (copyFails) return null;
        final name = lastRelativePath!.split('/').last;
        final file = File('${cacheDir.path}/share_999_$name')
          ..writeAsBytesSync(<int>[4, 5, 6]);
        return file.path;
      case 'deleteTreeFile':
        lastDeleteTreeUri = args['treeUri'] as String?;
        lastDeleteRelativePath = args['relativePath'] as String?;
        return deleteResult;
      case 'persistedTreeUris':
        return persistedUris;
      default:
        return null;
    }
  }
}

void main() {
  const channel = MethodChannel('zlibx/media_store');
  late Directory tempDir;
  late Directory sourceRoot;
  late _FakeSaf fake;

  /// The granted folder's real path in these tests.
  late String treeRoot;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('saf_');
    sourceRoot = Directory.systemTemp.createTempSync('saf_root_');
    treeRoot = '${sourceRoot.path}/Download/zlibx';
    fake = _FakeSaf()..cacheDir = tempDir;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fake.handle);
    SafFolderAccess.forceAndroidForTesting = true;
    SafFolderAccess.treeRootForTesting = treeRoot;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SafFolderAccess.forceAndroidForTesting = false;
    SafFolderAccess.treeUriForTesting = null;
    SafFolderAccess.treeRootForTesting = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    if (sourceRoot.existsSync()) sourceRoot.deleteSync(recursive: true);
  });

  group('pickFolder', () {
    test('stores the picked URI and returns it', () async {
      final uri = await SafFolderAccess().pickFolder();
      expect(uri, _kTreeUri);
      expect(SafFolderAccess.treeUriForTesting, _kTreeUri);
    });

    test('returns null when the picker is cancelled', () async {
      fake.pickResult = null;
      expect(await SafFolderAccess().pickFolder(), isNull);
      expect(SafFolderAccess.treeUriForTesting, isNull);
    });
  });

  group('hasGrant', () {
    test('is true with a stored URI without asking the channel', () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      expect(await SafFolderAccess().hasGrant, isTrue);
      expect(fake.calls, isNot(contains('persistedTreeUris')));
    });

    test('adopts a persisted Download grant', () async {
      fake.persistedUris = <String>[_kTreeUri];
      expect(await SafFolderAccess().hasGrant, isTrue);
      expect(SafFolderAccess.treeUriForTesting, _kTreeUri);
    });

    test('is false without any grant', () async {
      fake.persistedUris = <String>[];
      expect(await SafFolderAccess().hasGrant, isFalse);
    });

    test('ignores persisted grants outside Download', () async {
      fake.persistedUris = <String>[
        'content://com.android.externalstorage.documents/tree/primary%3ADocuments',
      ];
      expect(await SafFolderAccess().hasGrant, isFalse);
      expect(SafFolderAccess.treeUriForTesting, isNull);
    });
  });

  group('materialize', () {
    test('returns null without a grant', () async {
      fake.persistedUris = <String>[];
      expect(
        await SafFolderAccess()
            .materialize('$treeRoot/Book - 1.epub'),
        isNull,
      );
      expect(fake.copyCalls, 0);
    });

    test('copies via the channel with the right relative path', () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      final realPath = '$treeRoot/sub/Book - 1.epub';
      final cached = await SafFolderAccess().materialize(realPath);
      expect(fake.copyCalls, 1);
      expect(fake.lastTreeUri, _kTreeUri);
      expect(fake.lastRelativePath, 'sub/Book - 1.epub');
      expect(cached, isNotNull);
      expect(File(cached!).readAsBytesSync(), <int>[4, 5, 6]);
    });

    test('returns null for a path outside the tree', () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      expect(
        await SafFolderAccess()
            .materialize('${sourceRoot.path}/Download/other.epub'),
        isNull,
      );
      expect(fake.copyCalls, 0);
    });

    test('returns null when the channel copy fails', () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      fake.copyFails = true;
      expect(
        await SafFolderAccess()
            .materialize('$treeRoot/Book - 1.epub'),
        isNull,
      );
    });
  });

  group('canOpen', () {
    test('is true for a real file and false for a missing one', () async {
      final file = File('${tempDir.path}/book.epub')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      expect(await SafFolderAccess.canOpen(file.path), isTrue);
      expect(
        await SafFolderAccess.canOpen('${tempDir.path}/gone.epub'),
        isFalse,
      );
    });
  });

  group('readablePath', () {
    test('returns a content URI as-is', () async {
      const uri = 'content://media/external/downloads/1';
      expect(await SafFolderAccess().readablePath(uri), uri);
      expect(fake.calls, isEmpty);
    });

    test('returns an openable plain path as-is', () async {
      final file = File('${tempDir.path}/book.epub')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      expect(await SafFolderAccess().readablePath(file.path), file.path);
      expect(fake.copyCalls, 0);
    });

    test('materializes an unreadable plain path under the tree', () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      final cached = await SafFolderAccess()
          .readablePath('$treeRoot/Orphan - 2.epub');
      expect(fake.lastRelativePath, 'Orphan - 2.epub');
      expect(cached, isNotNull);
      expect(File(cached!).readAsBytesSync(), <int>[4, 5, 6]);
    });

    test('returns null when there is no grant and the file cannot open',
        () async {
      fake.persistedUris = <String>[];
      expect(
        await SafFolderAccess()
            .readablePath('$treeRoot/Orphan - 2.epub'),
        isNull,
      );
    });
  });

  group('deleteTreeFile', () {
    test('deletes through the channel with the right relative path',
        () async {
      SafFolderAccess.treeUriForTesting = _kTreeUri;
      expect(
        await SafFolderAccess()
            .deleteTreeFile('$treeRoot/Book - 1.epub'),
        isTrue,
      );
      expect(fake.lastDeleteTreeUri, _kTreeUri);
      expect(fake.lastDeleteRelativePath, 'Book - 1.epub');
    });

    test('returns false without a grant', () async {
      fake.persistedUris = <String>[];
      expect(
        await SafFolderAccess()
            .deleteTreeFile('$treeRoot/Book - 1.epub'),
        isFalse,
      );
    });
  });
}
