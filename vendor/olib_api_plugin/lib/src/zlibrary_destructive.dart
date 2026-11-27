// Destructive GETs of [ZLibraryApiBase] (plan item 5): the
// dedicated no-retry, no-redirect client and the single-attempt
// GET for calls that change server state. Split out of
// `zlibrary_api.dart` (review-2 P1-4) as a private extension on
// [ZLibraryApiBase] in the same library, so it can use the base
// class's private session state directly; every call site stays
// byte-identical.
part of 'zlibrary_api.dart';

/// Destructive-GET helpers for [ZLibraryApiBase].
extension _ZLibraryApiDestructive on ZLibraryApiBase {
  // ── Destructive GETs (plan item 5) ──────────────────────────────

  /// The dedicated client for destructive GETs: same timeouts and
  /// headers as the main client, but a separate instance, so a
  /// destructive call never shares state with the read client.
  ///
  /// Dio 5 note: `retryOnConnectionFailure` (a Dio 4 option) does not
  /// exist in Dio 5.11.1 — the adapter never retries a failed
  /// connection — so the single-attempt guarantee below is structural:
  /// [_getDestructive] issues one request and only loops for the
  /// wall-challenge hop.
  Dio _destructiveClient() => _destructiveDio ??= Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          headers: {
            'User-Agent': kZLibraryUserAgent,
            'Accept': 'application/json',
          },
        ),
      );

  /// GET for calls that change server state (booklist remove / delete),
  /// through the dedicated client. Exactly ONE attempt, no redirect
  /// following, no resend:
  ///
  ///  * a transport error, 4xx or 5xx returns an error [_Raw] — the
  ///    write may already have landed while the answer was lost, so a
  ///    retry could apply it twice. The caller keeps the record and
  ///    never auto-resends (the booklist detail provider restores the
  ///    removed row on failure);
  ///  * the only redirect ever followed is the DDoS-Guard challenge
  ///    hop: a 307 that carries DiamWall markers ([isDiamWallResponse])
  ///    and points back at the SAME URL (the booklist write endpoints
  ///    answer the first GET that way — 2026-11-09 packet capture — and
  ///    the follow-up must carry the `__diamwall` cookie the 307 set).
  ///    At most 3 such hops. Any other redirect (301/302/303, a 307
  ///    without the markers, or any hop to another host) returns an
  ///    error instead of re-issuing the write somewhere the caller
  ///    never asked for.
  Future<_Raw> _getDestructive(String path) async {
    final url = '$_base$path';
    var challengeHops = 0;
    for (;;) {
      final Response<String> res;
      try {
        res = await _destructiveClient().get<String>(
          url,
          options: Options(
            headers: _headers,
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 400,
          ),
        );
      } on DioException catch (e) {
        return _fromError(e);
      }
      final code = res.statusCode ?? 0;
      if (code != 301 &&
          code != 302 &&
          code != 303 &&
          code != 307 &&
          code != 308) {
        return await _fromResponse(res);
      }
      final location = res.headers.value(HttpHeaders.locationHeader);
      final sameUrl = location != null &&
          location.isNotEmpty &&
          ZLibraryApiBase._resolvesToSameUrl(url, location);
      if (code == 307 &&
          sameUrl &&
          challengeHops < 3 &&
          isDiamWallResponse(status: code, headers: res.headers)) {
        // Learn the challenge cookie before the follow-up. Same URL
        // by construction, so same-host only — nothing from another
        // host ever enters the jar here.
        _harvestRedirectCookies(
          res.headers['set-cookie'] ?? const <String>[],
        );
        challengeHops++;
        continue;
      }
      return _Raw(status: code, error: 'redirect not followed');
    }
  }
}
