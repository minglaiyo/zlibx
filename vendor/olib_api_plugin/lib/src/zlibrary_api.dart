import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';

import 'api_response.dart';
import 'article_search.dart';
import 'book.dart';
import 'book_comment.dart';
import 'book_detail_extras.dart';
import 'book_detail_html.dart';
import 'booklist.dart';
import 'category.dart';
import 'download_range.dart';
import 'download_stats.dart';
import 'fulltext.dart';
import 'user.dart';
import 'zlib_error.dart';

part 'zlibrary_auth.dart';
part 'zlibrary_search.dart';
part 'zlibrary_articles.dart';
part 'zlibrary_booklists.dart';
part 'zlibrary_categories.dart';
part 'zlibrary_authors.dart';
part 'zlibrary_dstats.dart';
part 'zlibrary_fulltext.dart';
part 'zlibrary_downloads.dart';
part 'zlibrary_info.dart';
part 'zlibrary_booklist_membership.dart';
part 'zlibrary_booklist_writes.dart';
part 'zlibrary_destructive.dart';
part 'zlibrary_download_types.dart';
part 'zlibrary_http.dart';
part 'zlibrary_responses.dart';

/// The one User-Agent the Z-Library client sends (review-2 P2-1):
/// a mobile Chrome UA — the eapi answers mobile clients. Single
/// source: the read client's [BaseOptions], the destructive client's
/// [BaseOptions], and [_headers]' default all read this const, so the
/// three can never drift apart again. The WebView-solved UA
/// ([ZLibraryApiBase._wallUserAgent]) overrides it per request when
/// set — the wall clearance was minted against that UA. The app's
/// non-Z-Library clients use their own constant instead
/// ([kDefaultUserAgent], `lib/services/http_client.dart`); do not
/// merge the two — the eapi expects a mobile client.
const String kZLibraryUserAgent =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    'Chrome/120.0 Mobile Safari/537.36';

/// Shared session and HTTP infrastructure for [ZLibraryApi] and its
/// domain mixins. Public — not library-private — on purpose:
/// [ZLibraryApi] extends this class and [ZLibraryAuth] constrains
/// on it, so a private base would put a private type in the
/// public API.
///
/// The HTTP method a redirect-following request starts with
/// (`ZLibraryApiBase._sendFollowing`). 301/302/303 turn the follow-up
/// into a GET; 307/308 keep the current method (browser behaviour).
/// Top-level, not a class member: Dart does not allow an enum
/// declaration inside a class.
enum _RedirectMethod { get, delete, post }

abstract class ZLibraryApiBase {
  static const String _defaultDomain = 'bookroom.lifestyle';

  final Dio _dio;
  String _domain;
  String? _userId;
  String? _userKey;

  /// Dedicated client for destructive GETs (plan item 5), injected in
  /// tests; production code never passes it — `_destructiveClient`
  /// builds it lazily. Kept separate from [_dio] so a destructive
  /// call never shares state with the read client.
  Dio? _destructiveDio;

  /// Wall-clearance cookies copied from the WebView's CookieManager
  /// after a challenge solve (`__diamwall`, `cf_clearance`, ...).
  /// They ride along in the same `Cookie` header as the session, so
  /// later HTML loads pass the wall through fast Dio instead of
  /// solving again. In-memory only, like the session — a fresh solve
  /// re-bridges them. The download path strips the whole `Cookie`
  /// header for cross-host links, so these never leak to a CDN.
  final Map<String, String> _wallCookies = {};

  /// The WebView User-Agent the current wall clearance was issued
  /// against (`cf_clearance` is commonly bound to the UA it was
  /// minted with). Set alongside the wall cookies after a solve; the
  /// default UA keeps answering until then. Not a credential — it
  /// travels with every request of this instance, including redirect
  /// hops (unlike the Cookie, which the download path strips).
  String? _wallUserAgent;

  /// 解析缓存钩子（2026-11-21）：短 hash → eapi 真 hash 的持久映射，
  /// app 接到 StorageService（library 盒）。lookup 命中就直接用真
  /// hash 取书；write 在解析成功后回写，键是 (bookId, 传入的原始
  /// hash)——调用方每次传原始值，坏映射下次解析自然覆盖。内容只有
  /// hash 字符串，无隐私面。null = 未接线（默认，不缓存）。
  static Future<String?> Function(String bookId, String hash)?
      resolveCacheLookup;
  static void Function(String bookId, String hash, String resolved)?
      resolveCacheWrite;

  /// [dio] is a test seam: a caller-provided client (with a fake
  /// adapter) replaces the default one. Production code never passes it.
  /// [destructiveDio] is the same seam for the plan-5 destructive
  /// client (`_destructiveClient`).
  ZLibraryApiBase({String? domain, Dio? dio, Dio? destructiveDio})
    : _domain = _cleanDomain(domain ?? _defaultDomain),
      _dio = dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              headers: {
                'User-Agent': kZLibraryUserAgent,
                'Accept': 'application/json',
              },
            ),
          ),
      _destructiveDio = destructiveDio;

  static String _cleanDomain(String domain) {
    var d = domain.trim();
    d = d.replaceFirst(RegExp(r'^https?://'), '');
    // Drop anything that is not the host (path / query / fragment / userinfo
    // would otherwise be baked into every request URL and could smuggle a
    // different host past the caller).
    final cut = d.indexOf(RegExp(r'[/?#]'));
    if (cut >= 0) d = d.substring(0, cut);
    final at = d.lastIndexOf('@');
    if (at >= 0) d = d.substring(at + 1);
    while (d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    return d;
  }

  String get _base => 'https://$_domain';

  Map<String, String> get _headers {
    final h = <String, String>{};
    // Z-Library's mobile eapi requires a client source marker on every
    // request: without `source: android`, POST /eapi/book/search answers
    // HTTP 400 `{"success":0,"error":"Access denied"}` even with a valid
    // session, while login / profile / popular are unaffected
    // (qgming/zlib-app ADR-076; heartleo/zlib v0.0.16). Sent on every
    // eapi request, value fixed lowercase `android`.
    h['source'] = 'android';
    // The wall-solved UA wins when set (clearance minted against it);
    // otherwise every request carries the single default UA — set
    // here as well as in the Dio BaseOptions so the default is
    // observable (and testable) on injected clients too. Same value
    // either way, so production requests are unchanged.
    h['User-Agent'] = _wallUserAgent ?? kZLibraryUserAgent;
    final parts = <String>[];
    if (_userId != null && _userKey != null) {
      parts.add('remix_userid=$_userId');
      parts.add('remix_userkey=$_userKey');
    }
    // Wall-clearance cookies ride in the same header, so the
    // download path's cross-host Cookie strip covers them too.
    for (final entry in _wallCookies.entries) {
      parts.add('${entry.key}=${entry.value}');
    }
    if (parts.isNotEmpty) h['Cookie'] = parts.join('; ');
    return h;
  }

  static bool _resolvesToSameUrl(String url, String location) {
    try {
      return Uri.parse(url).resolveUri(Uri.parse(location)).toString() ==
          url;
    } on FormatException {
      return false;
    }
  }

  /// POST a raw string body as `text/plain`, following redirects by
  /// hand — same pattern as the download path (downloadBook).
  ///
  /// The site's `papi/comments/*` endpoints answer the first POST with
  /// 307 to the same URL; 307/308 are re-POSTed with the same body,
  /// 301/302/303 are followed as GET (browser behaviour). The session
  /// Cookie is only sent to our own host: a hop to another host drops
  /// it (Dio's automatic following would re-send it to whatever host
  /// a 302 points at). A same-host hop may re-issue cookies (the
  /// DDoS-Guard challenge sets `__diamwall` on the first 307 and
  /// expects the follow-up request to carry it): they are learned into
  /// the session / wall-cookie jar before following. Cross-host target
  /// hops learn nothing.
  ///
  /// Redirect failures (no Location, non-https target, too many hops,
  /// unparsable Location) return an error [_Raw] — never throw: the
  /// three callers only handle `ApiResponse.fail`, they do not catch
  /// [StateError].

  /// Form encoding: scalars as `key=value`, lists as repeated
  /// `key[]=value` — the PHP-style bracket convention the eapi server
  /// actually parses (`languages[]=german&extensions[]=epub`, as the
  /// official Android client and the working Python eapi clients send
  /// it). A bare repeated key (`extensions=epub`) is silently dropped
  /// by the search endpoint's array parser, so the search screen's
  /// format / language filter did nothing and other formats stayed in
  /// the results (device-reported 2026-11-12). The GET paths already
  /// emit the same bracket form via `ListFormat.multiCompatible` (see
  /// `_get` and the category search's `_encodeQuery`). The other
  /// `_postForm` callers (login / rpc / send_code / verify_code) send
  /// only scalar fields, so this changes nothing for them.
  static String _encodeForm(Map<String, dynamic> fields) {
    final parts = <String>[];
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is Iterable) {
        final key = Uri.encodeQueryComponent('${entry.key}[]');
        for (final item in value) {
          parts.add('$key=${Uri.encodeQueryComponent(item.toString())}');
        }
      } else {
        parts.add(
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(value.toString())}',
        );
      }
    }
    return parts.join('&');
  }

  /// Called at most once per rejection episode when the line refuses the
  /// session pair this client carries: an HTTP 401, or a JSON error body
  /// whose own message rejects the session.
  ///
  /// Without a hook the app only sees the empty or failing screens a
  /// dead session produces — mid-session nothing ever reached the auth
  /// state, so a rejected pair stayed in place until the next cold boot
  /// (2026-11-15, module 2: “401 不续期”). The app answers by re-verifying the
  /// pair once: a proxy that 401s a still-valid session then costs one
  /// profile call, and a genuinely rejected pair ends in a deliberate
  /// logout with a message instead of silent breakage.
  ///
  /// Only fired while a pair is installed, and only again after some
  /// call succeeded — a page of failing requests must not start one
  /// re-verification per request.
  void Function()? onSessionRejected;

  bool _sessionRejectionReported = false;

  /// Cloudflare block verdict for a response. The body markers alone
  /// are NOT enough: a 200 page (booklist, comments) whose text merely
  /// mentions the word used to be misread as a block and its content
  /// dropped. The markers only count on a Cloudflare-served response —
  /// status 403/503, or a `cf-ray` / `server: cloudflare` header.
  static bool _isCloudflareBlock({
    required String body,
    required int? status,
    Headers? headers,
  }) {
    final statusSuspect = status == 403 || status == 503;
    if (!statusSuspect) {
      if (headers == null) return false;
      final cfRay = headers.value('cf-ray');
      final server = headers.value('server');
      if (cfRay == null &&
          !(server?.toLowerCase().contains('cloudflare') ?? false)) {
        return false;
      }
    }
    return _looksLikeCloudflare(body);
  }

  /// The challenge page's markers sit in the first bytes of the body,
  /// so only the head is scanned: a full lowercase copy of a
  /// multi-MB HTML page is waste on every response.
  static bool _looksLikeCloudflare(String body) {
    final head = body.length > 4096 ? body.substring(0, 4096) : body;
    final lower = head.toLowerCase();
    return lower.contains('cloudflare') ||
        lower.contains('attention required') ||
        lower.contains('cf-challenge');
  }

  /// Markers of a DDoS-Guard / Cloudflare browser-check page (the
  /// mirror answers HTML page routes with HTTP 503 + this page when it
  /// walls Dio). Checked against the raw error body in `_fromError` so
  /// the challenge HTML never reaches the UI as an error string.
  static bool _looksLikeChallengePage(String body) {
    final lower = body.toLowerCase();
    return lower.contains('checking your browser') ||
        lower.contains('ddos-guard') ||
        lower.contains('cf-challenge') ||
        lower.contains('just a moment') ||
        lower.contains('attention required');
  }

  /// True when a server-supplied error message rejects the stored session.
  /// Delegates to the plan-10 error table ([classifyZlibError]): only the
  /// `sessionExpired` kind counts, so a refused request ("Access denied")
  /// or a wrong-password answer never reads as a bad session.
  static bool rejectsSessionMessage(String? message) =>
      classifyZlibError(message: message) == ZlibErrorKind.sessionExpired;

  /// The server's own words in a JSON error body: eapi uses `error`,
  /// papi-style payloads use `message`. Null when the object carries
  /// neither (or only blanks).
  static String? _jsonErrorMessage(Map<String, dynamic> json) {
    final msg = (json['error'] ?? json['message'])?.toString().trim();
    return (msg == null || msg.isEmpty) ? null : msg;
  }

  /// eapi success is `success: 1` (sometimes `true`); some list endpoints
  /// omit the flag and just return the payload, which also counts.
  static bool _isSuccess(Map<String, dynamic> json) {
    final s = json['success'];
    if (s == null) return true;
    if (s is bool) return s;
    if (s is num) return s != 0;
    return s.toString() == '1' || s.toString().toLowerCase() == 'true';
  }

  /// The eapi answers `{"success":0,"error":"Invalid hash"}` when the
  /// hash is not the one it issued for the book. The webpage short hash
  /// (the `/book/{hash}/...` link) and the card `termshash` are both
  /// rejected — only the hash from an eapi response works. Booklist,
  /// profile and shared books carry only the short hash, so callers
  /// that hit this error resolve the real one with resolveEapiHash.
  static bool _isInvalidHashError(String? error) =>
      error != null && error.toLowerCase().contains('invalid hash');

  static Map<String, dynamic>? _userJson(Map<String, dynamic> json) {
    for (final key in const ['user', 'data', 'profile']) {
      final v = json[key];
      if (v is Map<String, dynamic>) return v;
    }
    return null;
  }

  /// The site's JSON error strings sometimes carry HTML markup; toasts
  /// show it raw, so strip tags here. A line break becomes a space
  /// first so words don't run together.
  static String _plainError(String? value, String fallback) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return fallback;
    return text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
  }
  // ── Shared search helpers ────────────────────────────────────────
  // `search`, `resolveEapiHash`, `_booksOf` and `_metaOf` live in the
  // base (not in `ZLibrarySearch`): the search mixin calls `search`
  // from `getMostPopular`, `getRecently` and `similar`, and
  // `resolveEapiHash` from `getBookInfo`; the downloads mixin calls
  // `resolveEapiHash` from `_resolveDownloadLink`. A mixin can only
  // see its own members and its `on` types, so a method shared by
  // two mixins has to live here.


  Future<ApiResponse<List<Book>>> search({
    String? message,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int? page,
    int? limit,
    // Exact title match: sends form field `e=1`, the same flag the
    // full-text search already uses (see FullTextSearchParams).
    // Null/false sends nothing, so existing callers are unaffected.
    bool? exact,
    // Cancelled by the app layer when a newer search supersedes this
    // one: the in-flight request stops instead of running to
    // completion only for its result to be discarded by the caller's
    // request-id guard. Optional — every other caller passes nothing.
    CancelToken? cancelToken,
  }) async {
    final raw = await _postForm(
      '/eapi/book/search',
      {
      if (message != null) 'message': message,
      if (yearFrom != null) 'yearFrom': yearFrom,
      if (yearTo != null) 'yearTo': yearTo,
      if (languages != null) 'languages': languages,
      if (extensions != null) 'extensions': extensions,
      if (order != null) 'order': order,
      if (page != null) 'page': page,
      if (limit != null) 'limit': limit,
      if (exact == true) 'e': '1',
      },
      cancelToken: cancelToken,
    );
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'search failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'search failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(
      await ZLibraryApiBase.booksOfH(raw.json!, rawBody: raw.body),
      meta: _metaOf(raw.json!),
    );
  }

  Future<String?> resolveEapiHash(String bookId, String title) async {
    final res = await search(message: title, limit: 20);
    if (!res.success || res.data == null) return null;
    for (final book in res.data!) {
      if (book.id.toString() == bookId &&
          book.hash != null &&
          book.hash!.isNotEmpty) {
        return book.hash;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _metaOf(Map<String, dynamic> json) {
    final pagination = json['pagination'];
    if (pagination is Map<String, dynamic>) return pagination;
    final meta = json['meta'];
    if (meta is Map<String, dynamic>) return meta;
    return null;
  }

  static List<Book> _booksOf(Map<String, dynamic> json) {
    final raw = json['books'] ?? json['data'] ?? json['results'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Book.fromJson)
        .toList();
  }

  /// Hook-aware entry mirroring the other `parseXxxH` wrappers. When the
  /// host app injects [booksParseOverride] and a raw body is available, the
  /// whole decode runs on the Rust thread pool; otherwise it falls back to
  /// the synchronous Dart [_booksOf]. Behavior is identical either way —
  /// test/services/json_books_test.dart is the contract for both.
  static Future<List<Book>> booksOfH(
    Map<String, dynamic> json, {
    String? rawBody,
  }) async {
    final override = booksParseOverride;
    if (override != null && rawBody != null && rawBody.isNotEmpty) {
      return override(rawBody);
    }
    return _booksOf(json);
  }

  /// Public Dart-only fallback: decodes the raw JSON text through the same
  /// `_booksOf` + `Book.fromJson` pipeline. The host app's Rust hook calls
  /// this when the bridge is unavailable, so the fallback path stays in one
  /// place and never drifts from the primary parser.
  static List<Book> fallbackBooksOf(String rawJsonText) {
    // Mirror the Rust parser: invalid JSON is an empty list, never a throw.
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJsonText);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    return _booksOf(decoded);
  }
}

/// Injectable Rust parse hook for the eapi book-list JSON (the `_booksOf`
/// hot path). The host app sets this to a flutter_rust_bridge-backed
/// implementation returning the SAME `List<Book>`; when null (default) the
/// Dart `_booksOf` above is the fallback. Takes the raw response text (not
/// the decoded map) so the Rust side owns the whole decode + map pipeline.
Future<List<Book>> Function(String json)? booksParseOverride;

/// Z-Library client, rewritten from the call sites in olib-mobile.
///
/// Session model (matches what the app assumes):
/// - Auth is the `remix_userid` / `remix_userkey` pair, sent as a Cookie
///   header on every request. [login] learns the pair from the login
///   response (Set-Cookie headers and/or the user object);
///   [loginWithToken] installs a stored pair and re-validates it against
///   `/eapi/user/profile` directly, exactly as the app's auth comment says.
/// - [setDomain] only switches the base host; cookies are re-issued on the
///   new host by the app's reverify flow ([loginWithToken]).
///
/// Endpoint status (see README.md for the full table):
/// - Verified pattern from independent public eapi clients: login, profile,
///   search, book info, file link, saved, unsave, downloaded.
/// - Plausible by the same naming pattern, NOT yet verified against a live
///   account: most_popular, recommended, recently, similar, save,
///   send_code, verify_code. Those methods fall back or fail loudly rather
///   than silently returning wrong data; see their doc comments.

class ZLibraryApi extends ZLibraryApiBase with ZLibraryAuth, ZLibrarySearch, ZLibraryArticles, ZLibraryBooklists, ZLibraryBooklistWrites, ZLibraryBooklistMembership, ZLibraryCategories, ZLibraryAuthors, ZLibraryFullText, ZLibraryDownloads, ZLibraryDownloadHistory, ZLibraryInfo {
  ZLibraryApi({super.domain, super.dio, super.destructiveDio});

  String get domain => _domain;

  /// Switch the mirror host. Accepts a bare host or a full URL.
  void setDomain(String domain) {
    _domain = ZLibraryApiBase._cleanDomain(domain);
  }
}
