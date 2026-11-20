import 'package:flutter/foundation.dart';
import '../lib.dart' as frb_api;
import '../utils/diagnostics.dart';
import 'rust_init.dart';

/// P0-1: Rust-backed regex utilities, replacing scattered Dart `RegExp` calls.
///
/// The patterns live in `rust/zlibx_parsers/src/regex_utils.rs`, pre-compiled
/// via `OnceLock` and SIMD-accelerated by the `regex` crate. This module wraps
/// the async FRB bindings with a lazy-init + graceful-fallback guard, matching
/// the existing `rust_*` hook conventions (CLAUDE.md):
///
/// - The bridge initializes on the FIRST call, so app startup is never blocked.
/// - On any bridge failure the helper un-registers itself and every later call
///   goes straight to the Dart fallback — behavior stays identical either way.
///
/// These helpers are **async** because FRB crosses into the Rust thread pool.
/// Call sites that were synchronous (`RegExp(...).hasMatch`) must be moved to
/// an async context or keep the Dart fallback; the sync hot paths (download
/// range parsing) intentionally stay in Dart.
class RustRegex {
  RustRegex._();

  // ── Cached fallback patterns ─────────────────────────────────────────────
  // Dart does not guarantee that RegExp literals inside methods are cached
  // across calls. Extracting them as static finals ensures they are compiled
  // once and reused, matching the Rust side's OnceLock convention.

  // pagesTotal 的键可能带 JSON 引号（`"pagesTotal": 100`）——引号可选。
  // 正则用分段拼接表达（["' 交叉引号字符类 + raw 段承载 \s \d），
  // 避免在字符串字面量里做多层转义。
  static final _pagesTotalRe = RegExp(
    'pagesTotal["' "'" r']?\s*[:=]\s*"' r'?(\d+)',
  );
  static final _numericIdRe = RegExp(r'^\d+$');
  static final _hexTokenRe = RegExp(r'^[0-9a-fA-F]{8}$');
  static final _dateRe = RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}$');
  static final _timeRe = RegExp(r'^\d{1,2}:\d{2}$');
  static final _datePartsRe = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$');
  static final _timePartsRe = RegExp(r'^(\d{1,2}):(\d{2})$');
  static final _urlSchemeRe = RegExp(r'^https?://');
  static final _pathSepRe = RegExp(r'[/?#]');
  static final _scriptTagRe = RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true);
  static final _htmlCommentRe = RegExp(r'<!--[\s\S]*?-->');
  static final _whitespaceRe = RegExp(r'\s+');
  static final _categorySlugRe = RegExp(r'/category/\d+/([^/]+)/s/');

  /// Whether the Rust bridge is currently usable. Starts optimistic; flips to
  /// false permanently after the first init failure so we stop retrying.
  static bool _available = true;

  static Future<bool> _ensureBridge() async {
    if (!_available) return false;
    try {
      await ensureRustBridge();
      return true;
    } on Object catch (e) {
      if (kDebugMode) {
        logIgnored('frb_regex_init', e);
      }
      resetRustBridge();
      _available = false;
      return false;
    }
  }

  // ── pagesTotal extraction ────────────────────────────────────────────────

  /// Extract the total page count from a results-page HTML body.
  ///
  /// Mirrors Dart `RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html)` used by
  /// fulltext / category / booklist / article parsers. Falls back to Dart when
  /// the bridge is unavailable.
  static Future<int?> extractPagesTotal(String html) async {
    if (await _ensureBridge()) {
      try {
        final v = await frb_api.extractPagesTotal(html: html);
        return v;
      } on Object catch (e) {
        _logFallback('extractPagesTotal', e);
      }
    }
    return _dartExtractPagesTotal(html);
  }

  static int? _dartExtractPagesTotal(String html) {
    final m = _pagesTotalRe.firstMatch(html);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  // ── numeric ID validation ────────────────────────────────────────────────

  /// True when [s] is purely ASCII digits (booklist / comment IDs).
  static Future<bool> isNumericId(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.isNumericId(s: s);
      } on Object catch (e) {
        _logFallback('isNumericId', e);
      }
    }
    return _numericIdRe.hasMatch(s);
  }

  // ── hex token validation ─────────────────────────────────────────────────

  /// True when [s] is an 8-character hexadecimal session token.
  static Future<bool> isHexToken(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.isHexToken(s: s);
      } on Object catch (e) {
        _logFallback('isHexToken', e);
      }
    }
    return _hexTokenRe.hasMatch(s);
  }

  // ── date / time format detection ─────────────────────────────────────────

  /// True when [s] matches DD.MM.YYYY.
  static Future<bool> isDateText(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.isDateText(s: s);
      } on Object catch (e) {
        _logFallback('isDateText', e);
      }
    }
    return _dateRe.hasMatch(s);
  }

  /// True when [s] matches HH:mm.
  static Future<bool> isTimeText(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.isTimeText(s: s);
      } on Object catch (e) {
        _logFallback('isTimeText', e);
      }
    }
    return _timeRe.hasMatch(s);
  }

  /// Parse DD.MM.YYYY into (day, month, year); null when no match.
  static Future<(int, int, int)?> parseDateParts(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.parseDateParts(s: s);
      } on Object catch (e) {
        _logFallback('parseDateParts', e);
      }
    }
    final m = _datePartsRe.firstMatch(s);
    if (m == null) return null;
    return (
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  /// Parse HH:mm into (hour, minute); null when no match.
  static Future<(int, int)?> parseTimeParts(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.parseTimeParts(s: s);
      } on Object catch (e) {
        _logFallback('parseTimeParts', e);
      }
    }
    final m = _timePartsRe.firstMatch(s);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  // ── URL normalization ────────────────────────────────────────────────────

  /// Strip http:// or https:// prefix from a domain string.
  static Future<String> stripUrlScheme(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.stripUrlScheme(s: s);
      } on Object catch (e) {
        _logFallback('stripUrlScheme', e);
      }
    }
    return s.replaceFirst(_urlSchemeRe, '');
  }

  /// Cut a URL at the first `/`, `?`, or `#`.
  static Future<String> cutAtFirstPathSep(String s) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.cutAtFirstPathSep(s: s);
      } on Object catch (e) {
        _logFallback('cutAtFirstPathSep', e);
      }
    }
    final i = s.indexOf(_pathSepRe);
    return i < 0 ? s : s.substring(0, i);
  }

  // ── HTML cleanup ─────────────────────────────────────────────────────────

  /// Remove `<script>` tags and HTML comments, collapse whitespace runs.
  /// ⚠️ NOT safe for rendering — regex stripping can be bypassed by malformed
  /// HTML. Use only for text extraction / cache deduplication.
  static Future<String> cleanHtmlForCache(String html) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.cleanHtmlForCache(html: html);
      } on Object catch (e) {
        _logFallback('cleanHtmlForCache', e);
      }
    }
    var clean = html.replaceAll(_scriptTagRe, '');
    clean = clean.replaceAll(_htmlCommentRe, '');
    return clean.replaceAll(_whitespaceRe, ' ').trim();
  }

  // ── category slug ────────────────────────────────────────────────────────

  /// Extract the category slug from a form action like `/category/123/slug/s/`.
  static Future<String?> extractCategorySlug(String action) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.extractCategorySlug(action: action);
      } on Object catch (e) {
        _logFallback('extractCategorySlug', e);
      }
    }
    final m = _categorySlugRe.firstMatch(action);
    return m?.group(1);
  }

  // ── hidden input value ───────────────────────────────────────────────────

  /// Extract the echoed query value from a hidden `<input name=...>` field.
  static Future<String?> extractInputValue(
    String html,
    String inputName,
  ) async {
    if (await _ensureBridge()) {
      try {
        return await frb_api.extractInputValue(
          html: html,
          inputName: inputName,
        );
      } on Object catch (e) {
        _logFallback('extractInputValue', e);
      }
    }
    final escaped = RegExp.escape(inputName);
    // Dart 的 RegExp 遵循 JS 语法：内联旗标必须写成带冒号的修饰组
    // (?is:...)，裸 (?is) 抛 FormatException: Invalid group——这条
    // Dart 回退此前从未成功过（Rust 桥在时无人走到这里，测试暴露）。
    final m = RegExp(
      '(?is:<input[^>]*?(?:name=["\']$escaped["\'][^>]*?value=["\']([^"\']*)'
      '["\']|value=["\']([^"\']*)["\'][^>]*?name=["\']$escaped["\']))',
    ).firstMatch(html);
    if (m == null) return null;
    final v = (m.group(1) ?? m.group(2) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  static void _logFallback(String fn, Object error) {
    if (kDebugMode) {
      logIgnored('frb_regex_$fn', error);
    }
  }
}
