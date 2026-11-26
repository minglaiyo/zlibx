// ISBN tool (plan item 7): a Dart port of qgming/zlib-app's Isbn.kt
// (80 lines), backing item 1 (barcode scan-to-search). Pure functions,
// no dependencies.
//
//  * separators (space, `-`, `–`, `—`) are stripped and the result
//    uppercased before anything else;
//  * ISBN-10 / ISBN-13 checksums are validated, not just the shape;
//  * a 978-prefixed ISBN-13 converts to its ISBN-10 and back;
//  * [extractIsbns] splits an identifier string on `, ; | \n /`,
//    validates each piece, and drops ASINs — a `B` followed by 9
//    alphanumerics is 10 characters that look like an ISBN-10 but are
//    not one.
//
// The barcode scanner page is deliberately NOT rewired to this: its
// `isBookBarcode` is a format gate (978/979 + 10 digits), not a
// validator — adding checksum validation there would reject a
// mis-scanned barcode instead of searching it. The one clean wiring
// is the search box ([normalizeIsbnQuery]): a whole query that is a
// valid ISBN searches its canonical ISBN-13 digits.
library;

/// Strip separators (space, `-`, `–`, `—`) and uppercase.
String normalizeIsbn(String input) =>
    input.replaceAll(RegExp(r'[\s\-–—]'), '').toUpperCase();

/// True when [input] is a valid ISBN-10 (10 chars, digits with an
/// optional `X` check digit, weighted sum 10..1 divisible by 11).
bool isValidIsbn10(String input) {
  final s = normalizeIsbn(input);
  if (s.length != 10) return false;
  var sum = 0;
  for (var i = 0; i < 9; i++) {
    final digit = int.tryParse(s[i]);
    if (digit == null) return false;
    sum += digit * (10 - i);
  }
  final check = s[9];
  final checkValue = check == 'X' ? 10 : int.tryParse(check);
  if (checkValue == null) return false;
  sum += checkValue;
  return sum % 11 == 0;
}

/// True when [input] is a valid ISBN-13 (13 digits, alternating 1/3
/// weights, sum divisible by 10).
bool isValidIsbn13(String input) {
  final s = normalizeIsbn(input);
  if (s.length != 13 || !RegExp(r'^\d{13}$').hasMatch(s)) return false;
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(s[i]) * (i.isEven ? 1 : 3);
  }
  return (10 - (sum % 10)) % 10 == int.parse(s[12]);
}

/// True when [input] is a valid ISBN-10 or ISBN-13.
bool isValidIsbn(String input) => isValidIsbn10(input) || isValidIsbn13(input);

/// 978-prefixed ISBN-13 -> its ISBN-10. Null when [input] is not a
/// valid 978 ISBN-13 (979-prefixed ISBN-13s have no ISBN-10).
String? isbn13ToIsbn10(String input) {
  final s = normalizeIsbn(input);
  if (!isValidIsbn13(s) || !s.startsWith('978')) return null;
  final body = s.substring(3, 12);
  var sum = 0;
  for (var i = 0; i < 9; i++) {
    sum += int.parse(body[i]) * (10 - i);
  }
  final check = (11 - (sum % 11)) % 11;
  return '$body${check == 10 ? 'X' : check}';
}

/// ISBN-10 -> its 978-prefixed ISBN-13. Null when [input] is not a
/// valid ISBN-10.
String? isbn10ToIsbn13(String input) {
  final s = normalizeIsbn(input);
  if (!isValidIsbn10(s)) return null;
  final body = '978${s.substring(0, 9)}';
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(body[i]) * (i.isEven ? 1 : 3);
  }
  return '$body${(10 - (sum % 10)) % 10}';
}

/// Canonical form for search: the ISBN-13 digits (an ISBN-10 is
/// converted to its 978 ISBN-13). Null when [input] is not a valid
/// ISBN of either form.
String? canonicalIsbnForSearch(String input) {
  final s = normalizeIsbn(input);
  if (isValidIsbn13(s)) return s;
  return isbn10ToIsbn13(s);
}

/// Split an identifier string on `, ; | \n /`, validate each piece,
/// and return the valid ISBNs in canonical (ISBN-13 digits) form,
/// deduplicated, in first-seen order. ASINs (`B` + 9 alphanumerics)
/// are excluded — they are not ISBNs, even though they are 10
/// characters long.
List<String> extractIsbns(String identifiers) {
  final seen = <String>{};
  final out = <String>[];
  for (final part in identifiers.split(RegExp(r'[,;|\n/]'))) {
    final s = normalizeIsbn(part);
    if (s.isEmpty || _isAsin(s)) continue;
    final canonical = canonicalIsbnForSearch(s);
    if (canonical != null && seen.add(canonical)) out.add(canonical);
  }
  return out;
}

bool _isAsin(String s) =>
    s.length == 10 &&
    s.startsWith('B') &&
    RegExp(r'^[A-Z0-9]{10}$').hasMatch(s);

/// Whole-query normalisation for the search box: when the user typed
/// or pasted a bare ISBN (with or without separators), search its
/// canonical ISBN-13 digits; anything else passes through unchanged.
String normalizeIsbnQuery(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return query;
  return canonicalIsbnForSearch(trimmed) ?? query;
}
