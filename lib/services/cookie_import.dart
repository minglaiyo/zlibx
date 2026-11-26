import 'dart:convert';

/// A session pair pasted by the user for Cookie import login (plan item 3).
///
/// Only the two session keys are ever taken out of the pasted text;
/// everything else in it is ignored, and no password is involved.
class ImportedCookie {
  const ImportedCookie({required this.userId, required this.userKey});

  final String userId;
  final String userKey;
}

/// Why [parseImportedCookie] could not find a usable session pair.
enum CookieImportError {
  /// The text matches none of the three supported shapes.
  unrecognized,

  /// A shape was recognised but it carries no `remix_userid`.
  missingUserId,

  /// A shape was recognised but it carries no `remix_userkey`.
  missingUserKey,
}

/// Thrown by [parseImportedCookie] when the pasted text has no usable
/// session pair. The UI maps [kind] to its message; the pasted text
/// itself is never logged (it is a credential).
class CookieImportException implements Exception {
  const CookieImportException(this.kind);

  final CookieImportError kind;

  @override
  String toString() => 'CookieImportException: $kind';
}

/// Parse pasted cookie text into a session pair.
///
/// Three shapes:
///
/// 1. JSON — a flat object (`{"remix_userid": "...", "remix_userkey":
///    "..."}`) or an array of `{"name": ..., "value": ...}` objects
///    (the shape browser cookie-export extensions write).
/// 2. Netscape `cookies.txt` — one cookie per line, tab- or
///    whitespace-separated fields
///    (`domain flag path secure expiration name value`), `#` comments
///    skipped.
/// 3. A raw `Cookie` header — `name=value; name=value; ...`.
///
/// Names match case-insensitively; values are trimmed and unquoted.
/// Only `remix_userid` / `remix_userkey` are read.
ImportedCookie parseImportedCookie(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    throw const CookieImportException(CookieImportError.unrecognized);
  }
  final pairs = <String, String>{};
  if (text.startsWith('{') || text.startsWith('[')) {
    final decoded = _decodeJson(text);
    if (decoded is Map<String, dynamic>) {
      _takeObjectPairs(pairs, decoded);
    } else if (decoded is List) {
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          final name = entry['name']?.toString();
          final value = entry['value']?.toString();
          if (name != null && value != null) {
            pairs[name.toLowerCase()] = _unquote(value.trim());
          }
        }
      }
    } else {
      throw const CookieImportException(CookieImportError.unrecognized);
    }
  } else {
    // Netscape first (line-based), then the raw header: the first
    // shape that yields any pair wins, so a header pasted with a stray
    // tab still parses instead of misreading as a cookie file.
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 7) continue;
      pairs[fields[5].trim().toLowerCase()] = _unquote(fields[6].trim());
    }
    if (pairs.isEmpty && text.contains('=')) {
      for (final part in text.split(';')) {
        final eq = part.indexOf('=');
        if (eq < 0) continue;
        final name = part.substring(0, eq).trim().toLowerCase();
        if (name.isEmpty) continue;
        pairs[name] = _unquote(part.substring(eq + 1).trim());
      }
    }
  }
  if (pairs.isEmpty) {
    throw const CookieImportException(CookieImportError.unrecognized);
  }
  final userId = pairs['remix_userid'];
  if (userId == null || userId.isEmpty) {
    throw const CookieImportException(CookieImportError.missingUserId);
  }
  final userKey = pairs['remix_userkey'];
  if (userKey == null || userKey.isEmpty) {
    throw const CookieImportException(CookieImportError.missingUserKey);
  }
  return ImportedCookie(userId: userId, userKey: userKey);
}

Object? _decodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    throw const CookieImportException(CookieImportError.unrecognized);
  }
}

void _takeObjectPairs(
  Map<String, String> pairs,
  Map<String, dynamic> json,
) {
  for (final entry in json.entries) {
    final value = entry.value;
    if (value == null) continue;
    pairs[entry.key.toLowerCase()] = _unquote(value.toString().trim());
  }
}

String _unquote(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
