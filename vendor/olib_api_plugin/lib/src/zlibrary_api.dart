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
import 'download_stats.dart';
import 'fulltext.dart';
import 'user.dart';

part 'zlibrary_auth.dart';
part 'zlibrary_search.dart';
part 'zlibrary_articles.dart';
part 'zlibrary_booklists.dart';
part 'zlibrary_categories.dart';
part 'zlibrary_dstats.dart';
part 'zlibrary_fulltext.dart';
part 'zlibrary_downloads.dart';

/// App-facing byte sink for the pending-MediaStore download flow
/// (Android 10+): the app streams bytes straight into an IS_PENDING
/// entry instead of staging a .part file. Implemented by the app's
/// PendingUriWriter; the plugin only ever calls these members, so it
/// has no dependency on app code. All engines keep their current
/// behaviour when no writer is passed.
abstract class PendingDownloadWriter {
  /// The MediaStore entry being filled (changes after [reset]).
  String get uri;

  /// Resume offset: bytes already committed (plus any buffered bytes).
  int get bytesWritten;

  /// Buffer one network chunk; may flush internally.
  Future<void> add(List<int> chunk);

  /// Commit all buffered bytes. Throws when the platform write fails.
  Future<void> flush();

  /// Delete the pending entry and all sidecars (cancel / bad content).
  Future<void> discard();

  /// Recreate the pending entry empty (server restarted the body).
  /// False when the new entry cannot be created.
  Future<bool> reset();
}

/// The server answered a download request with an HTML page (a
/// challenge / error page) instead of the file. Never resumable: the
/// destination (partial file or pending entry) is useless and must be
/// discarded, never resumed.
class DownloadHtmlException implements Exception {
  final String message;
  const DownloadHtmlException(this.message);
  @override
  String toString() => message;
}

/// Shared session and HTTP infrastructure for [ZLibraryApi] and its
/// domain mixins. Public — not library-private — on purpose:
/// [ZLibraryApi] extends this class and [ZLibraryAuth] constrains
/// on it, so a private base would put a private type in the
/// public API.
abstract class ZLibraryApiBase {
  static const String _defaultDomain = 'bookroom.lifestyle';

  final Dio _dio;
  String _domain;
  String? _userId;
  String? _userKey;

  /// Wall-clearance cookies copied from the WebView's CookieManager
  /// after a challenge solve (`__diamwall`, `cf_clearance`, ...).
  /// They ride along in the same `Cookie` header as the session, so
  /// later HTML loads pass the wall through fast Dio instead of
  /// solving again. In-memory only, like the session — a fresh solve
  /// re-bridges them. The download path strips the whole `Cookie`
  /// header for cross-host links, so these never leak to a CDN.
  final Map<String, String> _wallCookies = {};

  /// [dio] is a test seam: a caller-provided client (with a fake
  /// adapter) replaces the default one. Production code never passes it.
  ZLibraryApiBase({String? domain, Dio? dio})
    : _domain = _cleanDomain(domain ?? _defaultDomain),
      _dio = dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                    'Chrome/120.0 Mobile Safari/537.36',
                'Accept': 'application/json',
              },
            ),
          );

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

  /// Learn the cookies a redirect hop re-issued while following
  /// redirects by hand (`_getWithRedirects`, `_postText`, `_delete`). The
  /// DDoS-Guard challenge answers the first hop with 307 plus
  /// `set-cookie: __diamwall=...` and expects the follow-up request to
  /// carry it (2026-11-09 packet capture) — dropping them sent the
  /// follow-up out without the challenge cookie the wall had just set.
  /// The calling helpers only harvest on a hop that stays on our own host:
  /// another host's cookies never
  /// enter the jar.
  ///
  /// Parsing matches what login learns from Set-Cookie
  /// (`_learnSession`): each header is split on `;` and only the first
  /// segment counts (the name=value pair — `Path` / `Expires` /
  /// `HttpOnly` attributes are dropped), name and value split on the
  /// FIRST `=` only (values may contain `=`, base64 padding), and an
  /// empty value is skipped. The split follows login too:
  /// `remix_userid` / `remix_userkey` refresh the session pair,
  /// everything else merges into the wall-cookie jar by name (a newer
  /// value replaces its own name, other names are kept).
  void _harvestRedirectCookies(List<String> setCookies) {
    for (final cookie in setCookies) {
      final pair = cookie.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (value.isEmpty) continue;
      if (name == 'remix_userid') {
        _userId = value;
      } else if (name == 'remix_userkey') {
        _userKey = value;
      } else {
        _wallCookies[name] = value;
      }
    }
  }

  // ── Low-level helpers ──────────────────────────────────────────────

  Future<_Raw> _get(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? extraHeaders,
  }) async {
    try {
      final res = await _dio.get<String>(
        '$_base$path',
        queryParameters: query,
        options: Options(
          headers: {..._headers, ...?extraHeaders},
          responseType: ResponseType.plain,
          followRedirects: false,
          // Multi-value filters go out as `key[]=…`: Dio 5.9.2's
          // default is ListFormat.multi (bare repeated keys), NOT
          // multiCompatible — set it explicitly so bare list keys
          // encode with brackets. Scalars are unaffected.
          listFormat: ListFormat.multiCompatible,
        ),
      );
      return _fromResponse(res);
    } on DioException catch (e) {
      return _fromError(e);
    }
  }

  /// GET, following redirects by hand — same pattern as `_postText`.
  ///
  /// Shared by the booklists and categories domains: the booklists
  /// write endpoints 307 to the same URL, and a bare category URL
  /// (`/category/{id}`) 301/302s to its slugged form.
  ///
  /// The site's `papi/booklist/*` write endpoints answer the first GET
  /// with 307 to the same URL (the DDoS-Guard challenge sets a cookie
  /// and redirects); 307/308 are re-sent as GET, 301/302/303 are
  /// followed as GET (browser behaviour). The session Cookie is only
  /// sent to our own host: a hop to another host drops it (Dio's
  /// automatic following would re-send it to whatever host a 302
  /// points at). A same-host hop may re-issue cookies (the challenge's
  /// `__diamwall` on the first 307): they are learned into the session
  /// / wall-cookie jar before following. Cross-host target hops learn
  /// nothing.
  ///
  /// Redirect failures (no Location, non-https target, too many hops,
  /// unparsable Location) return an error [_Raw] — never throw: the
  /// callers only handle `ApiResponse.fail`, they do not catch
  /// [StateError].
  ///
  /// [receiveTimeout] overrides the Dio default (60s) for this call
  /// only; null keeps the default. Callers fetching a large HTML page
  /// on a slow link pass a longer one.
  /// The HTTP method a redirect-following request starts with. 301/302/303
  /// turn the follow-up into a GET; 307/308 keep the current method
  /// (browser behaviour).
  enum _RedirectMethod { get, delete, post }

  /// One redirect-following request: GET, DELETE or POST-with-a-text-body,
  /// following 301/302/303/307/308 by hand (max 5 hops).
  ///
  /// This is the single implementation behind [_getWithRedirects],
  /// [_delete] and [_postText] (S4): the three used to be near-identical
  /// ~70-line loops, so a security fix had to be applied in three places
  /// and could silently miss one. The behaviour is the old three:
  ///
  /// * 307/308 keep the current method (and the POST body); 301/302/303
  ///   turn the follow-up into a GET. (One latent fix: the old `_delete`
  ///   / `_postText` recomputed the method from the status code alone, so
  ///   a 307 seen after a 301 had already turned the request into a GET
  ///   wrongly switched it back to DELETE / POST. Keeping the *current*
  ///   method is the correct behaviour and is what this does.)
  /// * The session Cookie is only sent to our own host: a hop to another
  ///   host drops it, and it stays dropped even if a later hop comes back
  ///   (the `cookieStripped` flag). A same-host hop may re-issue cookies
  ///   (the DDoS-Guard challenge sets `__diamwall` on the first 307):
  ///   they are learned into the session / wall-cookie jar before
  ///   following, and the Cookie header is re-derived from the jar so the
  ///   follow-up carries them. Cross-host target hops learn nothing.
  /// * Redirect failures (no Location, non-https target, too many hops,
  ///   unparsable Location) return an error [_Raw] — never throw: the
  ///   callers only handle `ApiResponse.fail`, they do not catch
  ///   [StateError].
  ///
  /// [queryParameters] and [receiveTimeout] only apply to GET (the
  /// `_getWithRedirects` callers re-send the query on every hop, and one
  /// passes a longer timeout for large HTML pages); DELETE and POST pass
  /// neither. [body] / [contentType] only apply to POST.
  Future<_Raw> _sendFollowing(
    String path, {
    required _RedirectMethod method,
    String? body,
    String? contentType,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    var url = '$_base$path';
    var headers = Map<String, String>.from(_headers);
    if (extraHeaders != null) headers.addAll(extraHeaders);
    if (Uri.parse(url).host != Uri.parse(_base).host) {
      headers.remove('Cookie');
    }
    // Set once the Cookie header has been stripped for a cross-host hop:
    // it stays off for the rest of the chain even if a later hop comes
    // back to our own host (pre-fix behaviour).
    var cookieStripped = false;
    var currentMethod = method;
    var lastStatus = 0;
    for (var hop = 0; hop < 5; hop++) {
      try {
        final Response<String> res;
        switch (currentMethod) {
          case _RedirectMethod.get:
            res = await _dio.get<String>(
              url,
              // Re-sent on every hop: a redirect target (e.g. the
              // slugged category URL) carries no query of its own, so
              // the page/order/filter params belong on each request.
              queryParameters: queryParameters,
              options: Options(
                headers: headers,
                responseType: ResponseType.plain,
                followRedirects: false,
                validateStatus: (status) => status != null && status < 400,
                // Per-request override of the Dio default (60s); null
                // keeps it. Large HTML pages on a slow link need more
                // time — see fetchBookDetailExtras.
                receiveTimeout: receiveTimeout,
                // Same as [_get]: Dio 5.9.2's default is ListFormat.multi
                // (bare repeated keys) — set multiCompatible explicitly
                // so bare list keys encode as `key[]=…`.
                listFormat: ListFormat.multiCompatible,
              ),
            );
          case _RedirectMethod.delete:
            res = await _dio.delete<String>(
              url,
              options: Options(
                headers: headers,
                responseType: ResponseType.plain,
                followRedirects: false,
                validateStatus: (status) => status != null && status < 400,
              ),
            );
          case _RedirectMethod.post:
            res = await _dio.post<String>(
              url,
              data: body,
              options: Options(
                headers: headers,
                contentType: contentType,
                responseType: ResponseType.plain,
                followRedirects: false,
                validateStatus: (status) => status != null && status < 400,
              ),
            );
        }
        final code = res.statusCode ?? 0;
        lastStatus = code;
        if (code != 301 &&
            code != 302 &&
            code != 303 &&
            code != 307 &&
            code != 308) {
          return _fromResponse(res);
        }
        final location = res.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          return _Raw(status: code, error: 'redirect without location');
        }
        final Uri next;
        try {
          next = Uri.parse(url).resolveUri(Uri.parse(location));
        } on FormatException {
          return _Raw(status: code, error: 'redirect to invalid URL');
        }
        if (next.scheme != 'https') {
          return _Raw(status: code, error: 'redirect to non-https URL');
        }
        // Learn what this hop re-issued before following it. Only a hop
        // that stays on our own host may teach the jar: a cross-host
        // target's cookies must not enter it. The request host only
        // differs from the base after a cross-host target — and cookies
        // set by another host must not enter the jar even when that hop
        // redirects back to us.
        if (next.host == Uri.parse(_base).host &&
            Uri.parse(url).host == Uri.parse(_base).host) {
          _harvestRedirectCookies(
            res.headers['set-cookie'] ?? const <String>[],
          );
        }
        url = next.toString();
        if (next.host != Uri.parse(_base).host) {
          headers = Map<String, String>.from(headers)..remove('Cookie');
          cookieStripped = true;
        } else if (!cookieStripped) {
          // Same-host hop: re-derive the Cookie header from the jar so
          // the follow-up carries what this hop re-issued. Nothing was
          // harvested — the rebuild is a no-op.
          final cookie = _headers['Cookie'];
          if (cookie != null) {
            headers['Cookie'] = cookie;
          } else {
            headers.remove('Cookie');
          }
        }
        // 301/302/303 turn the follow-up into a GET; 307/308 keep the
        // current method (and the POST body).
        if (code != 307 && code != 308) {
          currentMethod = _RedirectMethod.get;
        }
      } on DioException catch (e) {
        return _fromError(e);
      }
    }
    return _Raw(status: lastStatus, error: 'too many redirects');
  }

  /// GET, following redirects by hand — see [_sendFollowing].
  ///
  /// Shared by the booklists and categories domains: the booklists
  /// write endpoints 307 to the same URL, and a bare category URL
  /// (`/category/{id}`) 301/302s to its slugged form.
  ///
  /// [receiveTimeout] overrides the Dio default (60s) for this call
  /// only; null keeps the default. Callers fetching a large HTML page
  /// on a slow link pass a longer one.
  Future<_Raw> _getWithRedirects(
    String path, {
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) {
    return _sendFollowing(
      path,
      method: _RedirectMethod.get,
      extraHeaders: extraHeaders,
      queryParameters: queryParameters,
      receiveTimeout: receiveTimeout,
    );
  }

  /// DELETE with no request body, following redirects by hand — see
  /// [_sendFollowing].
  Future<_Raw> _delete(String path) {
    return _sendFollowing(path, method: _RedirectMethod.delete);
  }

  /// POST a raw string body as `text/plain`, following redirects by
  /// hand — see [_sendFollowing].
  ///
  /// The site's `papi/comments/*` endpoints answer the first POST with
  /// 307 to the same URL; 307/308 are re-POSTed with the same body,
  /// 301/302/303 are followed as GET (browser behaviour).
  Future<_Raw> _postText(String path, String body) {
    return _sendFollowing(
      path,
      method: _RedirectMethod.post,
      body: body,
      contentType: 'text/plain;charset=UTF-8',
    );
  }
  /// DELETE with no request body, following redirects by hand — same
  /// pattern as `_postText`: 307/308 are re-sent as DELETE, 301/302/303
  /// are followed as GET (browser behaviour). The session Cookie is
  /// only sent to our own host: a hop to another host drops it. A
  /// same-host hop may re-issue cookies (the DDoS-Guard challenge sets
  /// `__diamwall` on the first 307 and expects the follow-up request to
  /// carry it): they are learned into the session / wall-cookie jar
  /// before following. Cross-host target hops learn nothing.
  ///
  /// Redirect failures (no Location, non-https target, too many hops,
  /// unparsable Location) return an error [_Raw] — never throw: the
  /// caller only handles `ApiResponse.fail`, it does not catch
  /// [StateError].



  Future<_Raw> _postForm(
    String path,
    Map<String, dynamic> fields,
  ) async {
    try {
      final res = await _dio.post<String>(
        '$_base$path',
        data: _encodeForm(fields),
        options: Options(
          headers: _headers,
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
      );
      return _fromResponse(res);
    } on DioException catch (e) {
      return _fromError(e);
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
  /// [_get] and the category search's `_encodeQuery`). The other
  /// [_postForm] callers (login / rpc / send_code / verify_code) send
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

  _Raw _fromResponse(Response<String> res) {
    final body = res.data ?? '';
    final status = res.statusCode;
    final cookies = res.headers['set-cookie'] ?? const <String>[];
    if (status == 403 && _looksLikeCloudflare(body)) {
      return _Raw(status: status, error: 'cf_blocked', cookies: cookies);
    }
    if (body.isEmpty) {
      return _Raw(
        status: status,
        error: 'empty response (HTTP $status)',
        cookies: cookies,
      );
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return _Raw(status: status, json: decoded, cookies: cookies);
      }
      return _Raw(status: status, error: 'unexpected response format');
    } on FormatException {
      if (_looksLikeCloudflare(body)) {
        return _Raw(status: status, error: 'cf_blocked');
      }
      // Not JSON — keep the raw body: the site's list pages (booklists)
      // are HTML, fetched with `Accept: text/html`. Set-Cookie is
      // forwarded too, so a session re-issued on an HTML page is not
      // silently dropped.
      return _Raw(
        status: status,
        error: 'non-JSON response (HTTP $status)',
        body: body,
        cookies: cookies,
      );
    }
  }

  _Raw _fromError(DioException e) {
    final res = e.response;
    final status = res?.statusCode;
    final body = res?.data?.toString() ?? '';
    if (status == 403 && _looksLikeCloudflare(body)) {
      return _Raw(status: status, error: 'cf_blocked');
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return _Raw(status: status, error: 'timeout: ${e.message}');
      case DioExceptionType.connectionError:
        return _Raw(status: status, error: 'connection error: ${e.message}');
      case DioExceptionType.badResponse:
        // Do NOT flatten the body away: EAPI answers failures with
        // HTTP 400 + {"success":0,"error":"..."} and the message is the
        // only thing that tells a bad request apart from bad credentials.
        // (The login dialog redacts emails/passwords before display.)
        if (body.isNotEmpty) {
          // A browser-check wall (DDoS-Guard / Cloudflare challenge
          // page) must not leak its raw HTML into error strings: the
          // booklists screen shows this text, and the full page is
          // unreadable noise there. A JSON error body never contains
          // these markers, so this runs before the JSON decode and
          // cannot swallow a real API error.
          if (_looksLikeChallengePage(body)) {
            return _Raw(
              status: status,
              error: 'HTTP $status: browser check page',
            );
          }
          try {
            final decoded = jsonDecode(body);
            if (decoded is Map<String, dynamic>) {
              final msg = (decoded['error'] ?? decoded['message'])
                  ?.toString()
                  .trim();
              if (msg != null && msg.isNotEmpty) {
                // Server error texts carry HTML markup (e.g. the
                // "Some errors occured" 500 wraps its identifier in
                // <b>…</b><br>); strip it here, at the source, so no
                // caller can show raw tags in a toast or dialog. This
                // is the path the booklist remove/delete 500s take —
                // the JSON success:0 branch already strips, this one
                // did not.
                return _Raw(status: status, error: _plainError(msg, msg));
              }
            }
          } on FormatException {
            // Not JSON: fall through to the truncated body below.
          }
          final snippet =
              body.length > 200 ? '${body.substring(0, 200)}…' : body;
          return _Raw(
            status: status,
            error: _plainError('HTTP $status: $snippet', 'HTTP $status'),
          );
        }
        return _Raw(status: status, error: 'HTTP $status');
      case DioExceptionType.cancel:
        return _Raw(status: status, error: 'cancelled');
      default:
        return _Raw(status: status, error: e.message ?? e.toString());
    }
  }

  static bool _looksLikeCloudflare(String body) {
    final lower = body.toLowerCase();
    return lower.contains('cloudflare') ||
        lower.contains('attention required') ||
        lower.contains('cf-challenge');
  }

  /// Markers of a DDoS-Guard / Cloudflare browser-check page (the
  /// mirror answers HTML page routes with HTTP 503 + this page when it
  /// walls Dio). Checked against the raw error body in [_fromError] so
  /// the challenge HTML never reaches the UI as an error string.
  static bool _looksLikeChallengePage(String body) {
    final lower = body.toLowerCase();
    return lower.contains('checking your browser') ||
        lower.contains('ddos-guard') ||
        lower.contains('cf-challenge') ||
        lower.contains('just a moment') ||
        lower.contains('attention required');
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
  }) async {
    final raw = await _postForm('/eapi/book/search', {
      if (message != null) 'message': message,
      if (yearFrom != null) 'yearFrom': yearFrom,
      if (yearTo != null) 'yearTo': yearTo,
      if (languages != null) 'languages': languages,
      if (extensions != null) 'extensions': extensions,
      if (order != null) 'order': order,
      if (page != null) 'page': page,
      if (limit != null) 'limit': limit,
      if (exact == true) 'e': '1',
    });
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
    return ApiResponse.ok(_booksOf(raw.json!), meta: _metaOf(raw.json!));
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
}

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

class ZLibraryApi extends ZLibraryApiBase with ZLibraryAuth, ZLibrarySearch, ZLibraryArticles, ZLibraryBooklists, ZLibraryCategories, ZLibraryFullText, ZLibraryDownloads, ZLibraryDownloadHistory {
  ZLibraryApi({super.domain, super.dio});

  String get domain => _domain;

  /// Switch the mirror host. Accepts a bare host or a full URL.
  void setDomain(String domain) {
    _domain = ZLibraryApiBase._cleanDomain(domain);
  }
}

class _Raw {
  final int? status;
  final Map<String, dynamic>? json;
  final String? error;
  final List<String> cookies;

  /// Raw response body, only filled when the response was not JSON
  /// (see [_fromResponse]) — the HTML list pages
  /// (fetched with `Accept: text/html`).
  final String? body;

  const _Raw({
    this.status,
    this.json,
    this.error,
    this.cookies = const <String>[],
    this.body,
  });
}

