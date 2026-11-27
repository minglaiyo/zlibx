import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:olib_api_plugin/src/download_range.dart';
import 'package:olib_api_plugin/src/zlibrary_api.dart';

// The two download engines (the plugin's Z-Library path and the app's
// external-source `ResumableDownloader`) share these rules through
// `DownloadRange` (O10) so an integrity fix lands once. The data here is
// synthetic header text; no network.
void main() {
  group('DownloadRange.canAppendPartialRange', () {
    test('Content-Range starting at the offset is proof enough', () {
      expect(
        DownloadRange.canAppendPartialRange('bytes 12-25/26', 12,
            ifRangeAccepted: false),
        isTrue,
      );
      expect(
        DownloadRange.canAppendPartialRange('bytes 13-25/26', 12,
            ifRangeAccepted: true),
        isFalse,
      );
    });

    // The rule that replaced "no validator recorded, transfer the whole
    // book again" (2026-11-15 perf): an offset with no Content-Range
    // proof is only trusted past an If-Range the server accepted.
    test('without Content-Range only an accepted If-Range is proof', () {
      expect(
        DownloadRange.canAppendPartialRange(null, 12, ifRangeAccepted: true),
        isTrue,
      );
      expect(
        DownloadRange.canAppendPartialRange(null, 12, ifRangeAccepted: false),
        isFalse,
      );
      expect(
        DownloadRange.canAppendPartialRange('bytes =?', 12,
            ifRangeAccepted: true),
        isTrue,
      );
      expect(
        DownloadRange.canAppendPartialRange('bytes =?', 12,
            ifRangeAccepted: false),
        isFalse,
      );
    });
  });

  group('DownloadRange Content-Range parsers', () {
    test('parses the start of a 206 range', () {
      expect(DownloadRange.parseContentRangeStart('bytes 12-25/26'), 12);
      expect(DownloadRange.parseContentRangeStart('BYTES 0-9/10'), 0);
    });

    test('parses the total of a 416 range', () {
      expect(DownloadRange.parseContentRangeTotal('bytes */26'), 26);
    });

    test('returns null for null, junk and a missing total', () {
      expect(DownloadRange.parseContentRangeStart(null), isNull);
      expect(DownloadRange.parseContentRangeStart('bytes */26'), isNull);
      expect(DownloadRange.parseContentRangeTotal('bytes 0-25/26'), isNull);
    });
  });

  group('DownloadRange.looksLikeHtml', () {
    test('sniffs the page doctypes and ignores a BOM or leading space', () {
      expect(DownloadRange.looksLikeHtml('<!DOCTYPE html>'.codeUnits), isTrue);
      expect(DownloadRange.looksLikeHtml('\n  <HTML>'.codeUnits), isTrue);
      expect(DownloadRange.looksLikeHtml([0x50, 0x4B, 3, 4]), isFalse);
      expect(DownloadRange.looksLikeHtml(const []), isFalse);
    });
  });

  // Phase 5: the rules that used to live twice (once per engine) —
  // metaPathFor / readValidator / resumeHeaders / validatorFromResponse
  // now land here once, and these tests pin them.
  group('DownloadRange.metaPathFor', () {
    test('appends .meta to the save path', () {
      expect(DownloadRange.metaPathFor('/a/b/book.part'), '/a/b/book.part.meta');
    });
  });

  group('DownloadRange.readValidator', () {
    test('reads back a written validator and trims it', () async {
      final dir = await Directory.systemTemp.createTemp('drange');
      try {
        final meta = File('${dir.path}/book.part.meta');
        await meta.writeAsString('  "etag-1"  \n');
        expect(await DownloadRange.readValidator(meta), '"etag-1"');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('null for a missing, empty or unreadable sidecar', () async {
      final dir = await Directory.systemTemp.createTemp('drange');
      try {
        expect(
          await DownloadRange.readValidator(File('${dir.path}/none.meta')),
          isNull,
        );
        final empty = File('${dir.path}/empty.meta')..writeAsStringSync('   ');
        expect(await DownloadRange.readValidator(empty), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('DownloadRange.resumeHeaders', () {
    test('start 0 carries only Accept-Encoding identity', () {
      final h = DownloadRange.resumeHeaders({'Cookie': 'x'}, 0, validator: null);
      expect(h['Accept-Encoding'], 'identity');
      expect(h.containsKey('Range'), isFalse);
      expect(h.containsKey('If-Range'), isFalse);
      // The input map is not mutated.
      expect(h.containsKey('Cookie'), isTrue);
    });

    test('start > 0 adds Range, and If-Range only with a validator', () {
      final without = DownloadRange.resumeHeaders(const {}, 12, validator: null);
      expect(without['Range'], 'bytes=12-');
      expect(without.containsKey('If-Range'), isFalse);

      final withV = DownloadRange.resumeHeaders(
        const {},
        12,
        validator: '"etag-1"',
      );
      expect(withV['Range'], 'bytes=12-');
      expect(withV['If-Range'], '"etag-1"');
    });
  });

  group('DownloadRange.validatorFromResponse', () {
    test('ETag wins over Last-Modified; neither gives null', () {
      final both = Headers.fromMap({
        HttpHeaders.etagHeader: ['"e1"'],
        HttpHeaders.lastModifiedHeader: ['yesterday'],
      });
      expect(DownloadRange.validatorFromResponse(both), '"e1"');

      final onlyLm = Headers.fromMap({
        HttpHeaders.lastModifiedHeader: ['yesterday'],
      });
      expect(DownloadRange.validatorFromResponse(onlyLm), 'yesterday');

      expect(DownloadRange.validatorFromResponse(Headers()), isNull);
    });
  });

  group('DownloadRange.discardPartialBytes', () {
    test('without a writer it truncates the partial file', () async {
      final dir = await Directory.systemTemp.createTemp('dlrange_discard');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/book.part');
      await file.writeAsBytes(List.filled(64, 0x51));

      expect(await DownloadRange.discardPartialBytes(file, null), isTrue);
      expect(await file.length(), 0);
    });

    test('with a writer it recreates the entry and keeps the file', () async {
      final dir = await Directory.systemTemp.createTemp('dlrange_discard');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/book.part');
      await file.writeAsBytes(List.filled(64, 0x51));

      final writer = _FakeWriter(resetResult: true);
      expect(await DownloadRange.discardPartialBytes(file, writer), isTrue);
      expect(writer.resetCalls, 1);
      expect(await file.length(), 64);

      final failing = _FakeWriter(resetResult: false);
      expect(await DownloadRange.discardPartialBytes(file, failing), isFalse);
      expect(failing.resetCalls, 1);
    });
  });

  group('DownloadRange.magicMatchesExtension', () {
    test('apk 是 ZIP：PK 头通过，HTML/文本头拒绝', () {
      expect(
        DownloadRange.magicMatchesExtension([0x50, 0x4B, 0x03, 0x04], 'apk'),
        isTrue,
      );
      expect(
        DownloadRange.magicMatchesExtension(
          '<!DOCTYPE html>'.codeUnits,
          'apk',
        ),
        isFalse,
      );
      expect(
        DownloadRange.magicMatchesExtension(
          '{"success":1}'.codeUnits,
          'apk',
        ),
        isFalse,
      );
    });

    test('太短、无法证伪的头放行（首包还没到不误杀）', () {
      expect(DownloadRange.magicMatchesExtension([0x50], 'apk'), isTrue);
      expect(DownloadRange.magicMatchesExtension([], 'apk'), isTrue);
    });
  });
}

/// Minimal stand-in for the app-side pending-MediaStore writer: counts
/// reset() calls and answers with a canned result.
class _FakeWriter implements PendingDownloadWriter {
  _FakeWriter({required this.resetResult});
  final bool resetResult;
  var resetCalls = 0;

  @override
  String get uri => 'content://fake/pending';

  @override
  int get bytesWritten => 0;

  @override
  Future<void> add(List<int> chunk) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> discard() async {}

  @override
  Future<bool> reset() async {
    resetCalls++;
    return resetResult;
  }
}
