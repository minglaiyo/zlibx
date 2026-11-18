import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:olib_api_plugin/src/download_range.dart';

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
}
