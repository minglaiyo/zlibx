// Server-supplied search-filter candidates (plan item 6): the
// language and extension lists the filter UI offers come from
// `GET /eapi/info/languages` (175 entries, code -> display name) and
// `GET /eapi/info/extensions` (12 entries, string array), merged over
// the hardcoded tables — the server can only ADD candidates, never
// remove or rename a local one (local entries keep their translations
// and their filter-sheet order; server-only codes are appended with
// the server's display name).
//
// Fetch failure (offline, not logged in, unexpected envelope) falls
// back to the hardcoded tables — the filter never goes empty. The
// server answers are cached in the settings box for 7 days so the
// filter does not wait on the network every time the screen opens;
// the provider itself is a FutureProvider, so one fetch serves the
// whole app run.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/search_filters.dart';
import '../services/hive_service.dart';
import '../utils/app_log.dart';
import 'zlibrary_provider.dart';

/// The filter vocabularies the search screen offers: the hardcoded
/// tables, plus any server-only candidates the last fetch added.
class SearchFilterOptions {
  /// Language entries by key (local table first, server-only codes
  /// appended).
  final Map<String, SearchLanguage> languages;

  /// API value per language key (`null` = all languages).
  final Map<String, String?> languageApiValues;

  /// API value per extension key (`null` = all formats).
  final Map<String, String?> extensions;

  const SearchFilterOptions({
    required this.languages,
    required this.languageApiValues,
    required this.extensions,
  });

  /// The hardcoded tables, with no server candidates — the fallback
  /// while the fetch is loading, and when it failed.
  factory SearchFilterOptions.local() => SearchFilterOptions(
        languages: Map<String, SearchLanguage>.of(searchLanguageOptions),
        languageApiValues: Map<String, String?>.of(searchLanguages),
        extensions: Map<String, String?>.of(searchExtensions),
      );
}

/// Merge server candidates over the hardcoded tables (pure function —
/// the unit tests cover it without network).
SearchFilterOptions mergeSearchFilterOptions({
  required Map<String, String> serverLanguages,
  required List<String> serverExtensions,
}) {
  final languages = Map<String, SearchLanguage>.of(searchLanguageOptions);
  final languageApiValues = Map<String, String?>.of(searchLanguages);
  for (final entry in serverLanguages.entries) {
    final code = entry.key.trim().toLowerCase();
    if (!_isValidLanguageCode(code)) continue;
    final name = entry.value.trim();
    if (name.isEmpty || name.length > 128) continue;
    // A local entry wins: it carries translations and a stable key.
    if (languages.containsKey(code)) continue;
    languages[code] = SearchLanguage(
      apiValue: code,
      zh: name,
      zhHant: name,
      en: name,
    );
    languageApiValues[code] = code;
  }
  final extensions = Map<String, String?>.of(searchExtensions);
  for (final raw in serverExtensions) {
    final code = raw.trim().toLowerCase();
    if (!_isValidExtensionCode(code)) continue;
    extensions.putIfAbsent(code, () => code);
  }
  return SearchFilterOptions(
    languages: languages,
    languageApiValues: languageApiValues,
    extensions: extensions,
  );
}

/// Server language codes are short lowercase identifiers (`english`,
/// `traditional_chinese`); anything else is not a code the eapi search
/// accepts, so it never reaches the filter UI.
bool _isValidLanguageCode(String code) =>
    RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(code);

/// Server extension codes are short lowercase alphanumerics (`epub`,
/// `azw3`); anything else never reaches the filter UI.
bool _isValidExtensionCode(String code) =>
    RegExp(r'^[a-z0-9]{1,16}$').hasMatch(code);

/// Server-supplied filter candidates, cached in the settings box.
final searchFilterOptionsProvider =
    FutureProvider<SearchFilterOptions>((ref) async {
  final cached = _readCachedOptions();
  if (cached != null &&
      DateTime.now().millisecondsSinceEpoch - cached._fetchedAtMs <
          _cacheTtl.inMilliseconds) {
    return mergeSearchFilterOptions(
      serverLanguages: cached._languages,
      serverExtensions: cached._extensions,
    );
  }
  try {
    final api = ref.read(zlibraryApiProvider);
    final languages = await api.getInfoLanguages();
    final extensions = await api.getInfoExtensions();
    if (languages.success &&
        languages.data != null &&
        extensions.success &&
        extensions.data != null) {
      await _writeCachedOptions(languages.data!, extensions.data!);
      return mergeSearchFilterOptions(
        serverLanguages: languages.data!,
        serverExtensions: extensions.data!,
      );
    }
  } catch (error) {
    AppLog.report(
      'Search filter options fetch failed: ${error.runtimeType}',
      tag: 'search_filter_options',
    );
  }
  // Fetch failed (or the server refused): a stale cache still beats
  // the hardcoded tables; without one the tables are the fallback.
  if (cached != null) {
    return mergeSearchFilterOptions(
      serverLanguages: cached._languages,
      serverExtensions: cached._extensions,
    );
  }
  return SearchFilterOptions.local();
});

const Duration _cacheTtl = Duration(days: 7);
const String _cacheKey = 'search_filter_options';

class _CachedOptions {
  final Map<String, String> _languages;
  final List<String> _extensions;
  final int _fetchedAtMs;

  const _CachedOptions(this._languages, this._extensions, this._fetchedAtMs);
}

_CachedOptions? _readCachedOptions() {
  final raw = HiveService.settingsBox.get(_cacheKey);
  if (raw is! Map) return null;
  final at = raw['at'];
  if (at is! int) return null;
  final languages = <String, String>{};
  final rawLanguages = raw['languages'];
  if (rawLanguages is Map) {
    for (final entry in rawLanguages.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is String) languages[key] = value;
    }
  }
  final extensions = <String>[];
  final rawExtensions = raw['extensions'];
  if (rawExtensions is List) {
    extensions.addAll(rawExtensions.whereType<String>());
  }
  return _CachedOptions(languages, extensions, at);
}

Future<void> _writeCachedOptions(
  Map<String, String> languages,
  List<String> extensions,
) async {
  try {
    await HiveService.settingsBox.put(_cacheKey, {
      'at': DateTime.now().millisecondsSinceEpoch,
      'languages': languages,
      'extensions': extensions,
    });
  } catch (error) {
    AppLog.report(
      'Failed to cache search filter options: ${error.runtimeType}',
      tag: 'search_filter_options',
    );
  }
}
