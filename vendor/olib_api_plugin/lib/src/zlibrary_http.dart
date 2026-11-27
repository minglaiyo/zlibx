// Low-level HTTP of [ZLibraryApiBase]: the plain GET, the
// redirect-following request core and its GET/DELETE/POST
// wrappers, and the form POST. Split out of `zlibrary_api.dart`
// (review-2 P1-4) as a private extension on [ZLibraryApiBase] in
// the same library, so it can use the base class's private
// session fields (`_dio`, `_headers`, `_base`, `_wallCookies`)
// directly. A separate library could not see those privates
// without changing the public interface (which the six test
// fakes implement); the extension keeps every call site — in
// the class, the domain mixins and the other extensions —
// byte-identical.
part of 'zlibrary_api.dart';

/// Low-level request helpers for [ZLibraryApiBase].
extension _ZLibraryApiHttp on ZLibraryApiBase {
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
      return await _fromResponse(res);
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
    CancelToken? cancelToken,
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
              cancelToken: cancelToken,
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
          return await _fromResponse(res);
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
    CancelToken? cancelToken,
  }) {
    return _sendFollowing(
      path,
      method: _RedirectMethod.get,
      extraHeaders: extraHeaders,
      queryParameters: queryParameters,
      receiveTimeout: receiveTimeout,
      cancelToken: cancelToken,
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
    Map<String, dynamic> fields, {
    // Only `search` takes one today: the app layer cancels a superseded
    // search instead of letting it finish. Optional, so the other
    // callers (login / rpc / send_code / verify_code) are untouched.
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.post<String>(
        '$_base$path',
        data: ZLibraryApiBase._encodeForm(fields),
        options: Options(
          headers: _headers,
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
        cancelToken: cancelToken,
      );
      return await _fromResponse(res);
    } on DioException catch (e) {
      return _fromError(e);
    }
  }
}
