// Response mapping of [ZLibraryApiBase]: the single funnel every
// request helper returns through, the session-rejection notice,
// and the raw answer type. Split out of `zlibrary_api.dart`
// (review-2 P1-4) as a private extension on [ZLibraryApiBase] in
// the same library, so it can use the base class's private
// session fields directly; every call site stays byte-identical.
part of 'zlibrary_api.dart';

/// Response-mapping helpers for [ZLibraryApiBase].
extension _ZLibraryApiResponses on ZLibraryApiBase {
  /// Single funnel for every answer: [_rawFromResponse] and
  /// [_rawFromError] are what all the request helpers return, so the
  /// rejection bookkeeping lives in one place.
  Future<_Raw> _fromResponse(Response<String> res) async {
    final raw = await _rawFromResponse(res);
    _noticeSessionRejection(raw);
    return raw;
  }

  _Raw _fromError(DioException e) {
    final raw = _rawFromError(e);
    _noticeSessionRejection(raw);
    return raw;
  }

  void _noticeSessionRejection(_Raw raw) {
    // An anonymous request that 401s says nothing about a stored pair.
    if (_userId == null || _userKey == null) return;
    if (!raw.authRejected) {
      // A usable answer with this pair: arm the notice again, so a
      // later rejection counts as a new episode. A transport failure
      // (no JSON at all) must not re-arm while we are mid-retry.
      if (raw.json != null) _sessionRejectionReported = false;
      return;
    }
    if (_sessionRejectionReported) return;
    _sessionRejectionReported = true;
    onSessionRejected?.call();
  }

  Future<_Raw> _rawFromResponse(Response<String> res) async {
    final body = res.data ?? '';
    final status = res.statusCode;
    final cookies = res.headers['set-cookie'] ?? const <String>[];
    if (ZLibraryApiBase._isCloudflareBlock(body: body, status: status, headers: res.headers)) {
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
      // P1-1 方案 A：大响应体（>64 KB，如 50 条书的搜索结果）在后台
      // isolate 里解码，免得 jsonDecode 堵 UI 线程；小响应仍在原地解，
      // 免得为几百字节多一次 isolate 往返。解码结果是纯数据，可跨
      // isolate 传递。第二次解析（booksParseOverride 走 Rust）不动，
      // 那次本就跑在 Rust 线程池上。
      final decoded = body.length > 64 * 1024
          ? await Isolate.run(() => jsonDecode(body))
          : jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        // A JSON failure that answers HTTP 200 (eapi says `success: 0`
        // with the reason in the body) is the same kind of verdict as a
        // JSON failure that answers 400 — including about the session.
        // Without this the 401-in-a-200 case would set `authRejected` in
        // `getProfile` but never reach the rejection hook below, so the
        // two paths would disagree about the same answer.
        return _Raw(
          status: status,
          json: decoded,
          cookies: cookies,
          // Keep the raw text only when a Rust-backed `booksParseOverride`
          // is injected — otherwise discard it to avoid doubling memory for
          // every JSON response. The host app sets this hook in main().
          body: booksParseOverride != null ? body : null,
          rejectedByMessage: !ZLibraryApiBase._isSuccess(decoded) &&
              ZLibraryApiBase.rejectsSessionMessage(ZLibraryApiBase._jsonErrorMessage(decoded)),
        );
      }
      return _Raw(status: status, error: 'unexpected response format');
    } on FormatException {
      if (ZLibraryApiBase._isCloudflareBlock(body: body, status: status, headers: res.headers)) {
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

  _Raw _rawFromError(DioException e) {
    final res = e.response;
    final status = res?.statusCode;
    // A stream-type response's data is a ResponseBody instance whose
    // toString() is "Instance of 'ResponseBody'" — pure noise in error
    // strings (2026-11-21: a download resuming with an empty hash hit
    // the file endpoint's 400 and surfaced exactly that). Treat it as
    // no body; the status code carries the message.
    final rawData = res?.data;
    final body = rawData is ResponseBody ? '' : rawData?.toString() ?? '';
    if (ZLibraryApiBase._isCloudflareBlock(
      body: body,
      status: status,
      headers: res?.headers,
    )) {
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
          if (ZLibraryApiBase._looksLikeChallengePage(body)) {
            return _Raw(
              status: status,
              error: 'HTTP $status: browser check page',
            );
          }
          try {
            final decoded = jsonDecode(body);
            if (decoded is Map<String, dynamic>) {
              final msg = ZLibraryApiBase._jsonErrorMessage(decoded);
              if (msg != null) {
                // Server error texts carry HTML markup (e.g. the
                // "Some errors occured" 500 wraps its identifier in
                // <b>…</b><br>); strip it here, at the source, so no
                // caller can show raw tags in a toast or dialog. This
                // is the path the booklist remove/delete 500s take —
                // the JSON success:0 branch already strips, this one
                // did not.
                return _Raw(
                  status: status,
                  error: ZLibraryApiBase._plainError(msg, msg),
                  rejectedByMessage: ZLibraryApiBase.rejectsSessionMessage(msg),
                );
              }
            }
          } on FormatException {
            // Not JSON: fall through to the truncated body below.
          }
          final snippet =
              body.length > 200 ? '${body.substring(0, 200)}…' : body;
          return _Raw(
            status: status,
            error: ZLibraryApiBase._plainError('HTTP $status: $snippet', 'HTTP $status'),
          );
        }
        return _Raw(status: status, error: 'HTTP $status');
      case DioExceptionType.cancel:
        return _Raw(status: status, error: 'cancelled');
      default:
        return _Raw(status: status, error: e.message ?? e.toString());
    }
  }
}

class _Raw {
  final int? status;
  final Map<String, dynamic>? json;
  final String? error;
  final List<String> cookies;

  /// Raw response body, only filled when the response was not JSON
  /// (see `_fromResponse`) — the HTML list pages
  /// (fetched with `Accept: text/html`).
  final String? body;

  /// HTTP 401, or a JSON error body whose own message rejects the session:
  /// the line looked at the `remix_*` pair this call carried and refused it.
  /// The only answers that say something about the credentials — a wall
  /// page, a 5xx, a 429 or a non-JSON body say something about the LINE,
  /// which is why they are not here. See `ApiResponse.authRejected`.
  bool get authRejected => status == 401 || rejectedByMessage;

  /// Set by `_fromError` when a JSON error body's message rejects the
  /// session (see [rejectsSessionMessage]).
  final bool rejectedByMessage;

  const _Raw({
    this.status,
    this.json,
    this.error,
    this.cookies = const <String>[],
    this.body,
    this.rejectedByMessage = false,
  });
}
