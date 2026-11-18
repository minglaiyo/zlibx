import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/core/rust_regex.dart';

/// Differential test for the P0-1 regex bridge.
///
/// `RustRegex.*` helpers run through flutter_rust_bridge when the native
/// library is present, and fall back to a hand-written Dart implementation
/// otherwise (CI has no Rust toolchain — see CLAUDE.md). Both paths must
/// return identical results for every pattern; this file is the contract.
void main() {
  group('extractPagesTotal', () {
    test('reads pagesTotal from a pagerOptions script', () async {
      const html = '<script>pagerOptions({pagesTotal: 42})</script>';
      expect(await RustRegex.extractPagesTotal(html), 42);
    });

    test('accepts JSON-style quoted key', () async {
      const html = '{"pagesTotal": 100}';
      expect(await RustRegex.extractPagesTotal(html), 100);
    });

    test('tolerates whitespace around the colon', () async {
      const html = 'pagesTotal   :   7';
      expect(await RustRegex.extractPagesTotal(html), 7);
    });

    test('returns null when marker absent', () async {
      expect(await RustRegex.extractPagesTotal('<html>nope</html>'), isNull);
    });
  });

  group('isNumericId', () {
    test('accepts pure digits', () async {
      expect(await RustRegex.isNumericId('4088695'), isTrue);
    });

    test('rejects empty / non-digit', () async {
      expect(await RustRegex.isNumericId(''), isFalse);
      expect(await RustRegex.isNumericId('abc'), isFalse);
      expect(await RustRegex.isNumericId('12.3'), isFalse);
    });
  });

  group('isHexToken', () {
    test('accepts 8 hex chars any case', () async {
      expect(await RustRegex.isHexToken('a1b2c3d4'), isTrue);
      expect(await RustRegex.isHexToken('AABBCCDD'), isTrue);
    });

    test('rejects wrong length or non-hex', () async {
      expect(await RustRegex.isHexToken('short'), isFalse);
      expect(await RustRegex.isHexToken('g1h2i3j4'), isFalse);
    });
  });

  group('date / time validation', () {
    test('isDateText matches DD.MM.YYYY only', () async {
      expect(await RustRegex.isDateText('15.03.2024'), isTrue);
      expect(await RustRegex.isDateText('2024-03-15'), isFalse);
    });

    test('isTimeText matches HH:mm shape', () async {
      expect(await RustRegex.isTimeText('9:30'), isTrue);
      expect(await RustRegex.isTimeText('14:05'), isTrue);
      // \d{1,2} matches "25" — semantic range checks stay in the caller.
      expect(await RustRegex.isTimeText('25:00'), isTrue);
    });

    test('parseDateParts splits components', () async {
      expect(await RustRegex.parseDateParts('15.03.2024'), (15, 3, 2024));
    });

    test('parseTimeParts splits components', () async {
      expect(await RustRegex.parseTimeParts('14:05'), (14, 5));
    });

    test('parse helpers return null on bad input', () async {
      expect(await RustRegex.parseDateParts('bad'), isNull);
      expect(await RustRegex.parseTimeParts('bad'), isNull);
    });
  });

  group('URL normalization', () {
    test('stripUrlScheme removes http(s) prefix', () async {
      expect(await RustRegex.stripUrlScheme('https://zlib.us'), 'zlib.us');
      expect(await RustRegex.stripUrlScheme('http://example.com'), 'example.com');
      expect(await RustRegex.stripUrlScheme('plain.domain'), 'plain.domain');
    });

    test('cutAtFirstPathSep truncates at / ? #', () async {
      expect(await RustRegex.cutAtFirstPathSep('domain/path?q=1'), 'domain');
      expect(await RustRegex.cutAtFirstPathSep('domain#frag'), 'domain');
      expect(await RustRegex.cutAtFirstPathSep('pure-domain'), 'pure-domain');
    });
  });

  group('cleanHtmlForCache', () {
    test('drops scripts, comments and collapses whitespace', () async {
      const dirty =
          '<div>Hello</div><script>alert("x")</script><!-- note --><p>World</p>';
      final clean = await RustRegex.cleanHtmlForCache(dirty);
      // Exact match ensures whitespace collapsing is deterministic.
      expect(clean, '<div>Hello</div><p>World</p>');
    });

    test('handles multiline scripts and nested whitespace', () async {
      const dirty = '  <script\n>var x=1;\n</script>  A   B  ';
      final clean = await RustRegex.cleanHtmlForCache(dirty);
      expect(clean, 'A B');
    });
  });

  group('extractCategorySlug', () {
    test('reads the slug segment', () async {
      expect(
        await RustRegex.extractCategorySlug('/category/123/fiction/s/'),
        'fiction',
      );
    });

    test('returns null for unrelated paths', () async {
      expect(await RustRegex.extractCategorySlug('/other/path/'), isNull);
    });
  });

  group('extractInputValue', () {
    test('reads value when name precedes it', () async {
      const html =
          '<form><input type="hidden" name="q" value="hello world"></form>';
      expect(await RustRegex.extractInputValue(html, 'q'), 'hello world');
    });

    test('reads value when it precedes name', () async {
      const html = '<input value="echo" name="token">';
      expect(await RustRegex.extractInputValue(html, 'token'), 'echo');
    });

    test('empty value yields null', () async {
      const html = '<input name="q" value="">';
      expect(await RustRegex.extractInputValue(html, 'q'), isNull);
    });

    test('missing field yields null', () async {
      expect(await RustRegex.extractInputValue('<p>x</p>', 'q'), isNull);
    });
  });
}
