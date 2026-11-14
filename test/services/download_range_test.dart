import 'package:flutter_test/flutter_test.dart';
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
}
