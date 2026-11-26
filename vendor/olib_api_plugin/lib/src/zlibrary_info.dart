// Server-supplied search-filter vocabularies (plan item 6): the
// language / extension candidates the filter UI offers, fetched from
// the server instead of written down in the app.
//
// The endpoints follow the eapi naming pattern (`/eapi/info/*`) and
// match qgming/zlib-app's info calls, but the exact envelope was never
// verified against a live account — so both parsers accept the
// enveloped form (`{"success":1,"languages":{...}}` /
// `{"success":1,"extensions":[...]}`) and the bare form (the map /
// list itself), and anything else fails loudly instead of returning a
// wrong list. The app falls back to its hardcoded tables on failure
// (see SearchFilterOptionsProvider).
part of 'zlibrary_api.dart';

/// Info-endpoint methods for [ZLibraryApi].
mixin ZLibraryInfo on ZLibraryApiBase {
  /// `GET /eapi/info/languages`: the server's language candidates —
  /// 175 entries, a code -> display-name object.
  Future<ApiResponse<Map<String, String>>> getInfoLanguages() async {
    final raw = await _get('/eapi/info/languages');
    if (raw.json == null) {
      return ApiResponse.fail(
        raw.error ?? 'info languages failed',
        statusCode: raw.status,
      );
    }
    final languages = _languagesOf(raw.json!);
    if (languages == null) {
      return ApiResponse.fail(
        'unexpected response format',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(languages);
  }

  /// `GET /eapi/info/extensions`: the server's format candidates —
  /// 12 entries, a string array.
  Future<ApiResponse<List<String>>> getInfoExtensions() async {
    final raw = await _get('/eapi/info/extensions');
    if (raw.json == null) {
      return ApiResponse.fail(
        raw.error ?? 'info extensions failed',
        statusCode: raw.status,
      );
    }
    final extensions = _extensionsOf(raw.json!);
    if (extensions == null) {
      return ApiResponse.fail(
        'unexpected response format',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(extensions);
  }

  static Map<String, String>? _languagesOf(Map<String, dynamic> json) {
    final raw = json['languages'];
    if (raw is Map) return _stringMap(raw);
    // No envelope and no success flag: the object itself is the
    // code -> name map. A `success: 0` failure body never reaches
    // here — it carries the flag, so it falls through to null.
    if (json['success'] == null) return _stringMap(json);
    return null;
  }

  static Map<String, String>? _stringMap(Map<dynamic, dynamic> raw) {
    final map = <String, String>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is String && value.trim().isNotEmpty) {
        map[entry.key.toString()] = value;
      }
    }
    return map.isEmpty ? null : map;
  }

  static List<String>? _extensionsOf(Map<String, dynamic> json) {
    final raw = json['extensions'] ?? json['data'];
    if (raw is! List) return null;
    final list = raw
        .whereType<String>()
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
    return list.isEmpty ? null : list;
  }
}
