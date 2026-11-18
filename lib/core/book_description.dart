// Ported from warreth/OpenlibExtended (AGPL-3.0) — description
// normalisation for book detail pages.
// Original file: lib/core/book_description.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.

/// Missing metadata must remain absent rather than becoming the word "null".
///
/// Z-Library / Anna descriptions often arrive as raw HTML
/// (`<p>…</p>`, `<br>`, `&nbsp;` …) and the detail page renders plain
/// [Text], so strip the tags, decode entities and collapse whitespace
/// here — this is the single choke point for every detail screen
/// (Z-Library, Anna / LibGen).
String? normalizedBookDescription(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty || text.toLowerCase() == 'null') return null;

  // Paragraph breaks stay paragraphs; a lone <br> is a soft break.
  var plain = text
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  plain = _decodeHtmlEntities(plain);
  final paragraphs = plain
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll(RegExp(r'\s+'), ' ').trim())
      .map(_fixCjkPunctuationSpacing)
      .where((p) => p.isNotEmpty)
      .toList();
  if (paragraphs.isEmpty) return null;
  return paragraphs.join('\n\n');
}

const _namedEntities = <String, String>{
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'copy': '©',
  'reg': '®',
  'trade': '™',
};

String _decodeHtmlEntities(String text) {
  final decoded = text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);', caseSensitive: false),
    (match) {
      final body = match[1]!;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        final code = int.tryParse(body.substring(2), radix: 16);
        if (code == null || code > 0x10FFFF) return match[0]!;
        return String.fromCharCode(code);
      }
      if (body.startsWith('#')) {
        final code = int.tryParse(body.substring(1));
        if (code == null || code > 0x10FFFF) return match[0]!;
        return String.fromCharCode(code);
      }
      return _namedEntities[body] ?? match[0]!;
    },
  );
  // &amp; last, so "&amp;lt;" decodes to "&lt;" rather than "<".
  return decoded.replaceAll('&amp;', '&');
}

/// "&nbsp;" before a closing CJK punctuation mark leaves a stray space
/// ("[1] 。") — drop it. NOTE: Dart's `replaceAll` takes the replacement
/// literally (no `$1` group interpolation — that is what `replaceAllMapped`
/// is for), so a `$1` replacement here would have written a literal "$1"
/// into the text; use `replaceAllMapped` and return the captured group.
String _fixCjkPunctuationSpacing(String paragraph) => paragraph
    .replaceAllMapped(RegExp(r' ([，。；：、！？）】》」』])'), (match) => match[1]!);
