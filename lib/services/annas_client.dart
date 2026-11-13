part of 'annas_archieve.dart';

/// Request pipeline shared by search and bookInfo: retry across the
/// enabled mirrors, plain HTTP fetch, challenge/status checks, and
/// NetworkError conversion.
mixin _AnnasClientMixin on _AnnasArchieveBase {
  // Convert DioException to user-friendly NetworkError with async diagnostics
  Future<NetworkError> _handleErrorAsync(dynamic error,
      {String? responseBody, String? targetHost}) async {
    return await NetworkError.fromExceptionAsync(error,
        responseBody: responseBody, targetHost: targetHost);
  }

  // Try request with optimized retry logic - fast failure and fallback
  Future<T> _requestWithRetry<T>(
    Future<T> Function(String baseUrl, CancelToken cancelToken) requestFn,
  ) async {
    // Anna's Archive requests must only retry across Anna's mirrors -
    // libgen/zlib mirrors 404 on AA paths and waste every retry slot.
    // The list comes from open-slum.org; down mirrors are already
    // filtered out and the easiest (least protected) mirror comes first.
    final urls = await _instanceManager.enabledUrls(MirrorService.annasArchive);

    if (urls.isEmpty) {
      _logger.error('No attemptable Anna\'s Archive mirror',
          tag: 'AnnasArchive');
      throw await _handleErrorAsync(
        Exception('No Anna\'s Archive mirror is available right now'),
      );
    }

    Exception? lastException;
    String? lastUsedHost;

    // Try each mirror - they are already ordered by open-slum.org data
    // (protection difficulty, then SLUM latency).
    for (int i = 0; i < urls.length; i++) {
      final baseUrl = urls[i];
      lastUsedHost = baseUrl;

      // Fewer retries for subsequent mirrors (they're slower)
      final retriesForThis = i == 0 ? AnnasArchieve.maxRetriesPerInstance : 0;

      for (int attempt = 0; attempt <= retriesForThis; attempt++) {
        try {
          // First mirror gets the full timeout; later mirrors get half.
          final timeoutSeconds =
              i == 0 ? AnnasArchieve.requestTimeoutSeconds : AnnasArchieve.subsequentRequestTimeoutSeconds;
          // One token per attempt: on timeout the underlying Dio
          // request is cancelled instead of downloading in the
          // background while the retry loop moves on. The TimeoutException
          // below is caught by the retry loop (no rethrow) so the next
          // mirror/attempt still runs.
          final cancelToken = CancelToken();
          // Apply timeout to the request function
          final result = await requestFn(baseUrl, cancelToken).timeout(
            Duration(seconds: timeoutSeconds),
            onTimeout: () {
              cancelToken.cancel();
              throw TimeoutException(
                  "Request timed out after ${timeoutSeconds}s");
            },
          );

          // Success - log which mirror worked
          _logger.debug('Request succeeded on attempt ${attempt + 1}',
              tag: 'AnnasArchive', metadata: {'mirror': baseUrl});

          return result;
        } catch (e) {
          lastException = e is Exception ? e : Exception(e.toString());

          _logger.debug('Instance failed', tag: 'AnnasArchive', metadata: {
            'mirror': baseUrl,
            'attempt': attempt + 1,
            'error': e.toString().substring(
                0, (e.toString().length > 50) ? 50 : e.toString().length),
          });

          // Short delay before retry (only if we're retrying this instance)
          if (attempt < retriesForThis) {
            await Future.delayed(const Duration(milliseconds: AnnasArchieve.retryDelayMs));
          }
        }
      }
    }

    // All instances failed - throw with diagnostic info
    _logger.error('All instances failed', tag: 'AnnasArchive');

    // Throw a diagnostic NetworkError instead of the raw exception
    throw await _handleErrorAsync(
      lastException ?? Exception('All instances failed'),
      targetHost: lastUsedHost,
    );
  }

  // Plain HTTP fetch. No cookie replay: DDoS-Guard clearance is bound to the
  // browser's TLS fingerprint, so stored cookies never help here. Blocked
  // requests surface as cloudflareBlock and the webview solver takes over.
  Future<Response<dynamic>> _makeRequest(
    String url, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final requestHeaders = <String, dynamic>{
      ...defaultDioHeaders,
      if (headers != null) ...headers,
    };
    // Accept any status: a Cloudflare 403 challenge must reach
    // [_isChallengeResponse] and the solver instead of dying as a raw
    // DioException before the challenge logic ever runs. Non-challenge
    // error statuses are turned back into a network failure by
    // [_ensureResponseStatus].
    return await dio.get(
      url,
      options: Options(
        headers: requestHeaders,
        validateStatus: (_) => true,
      ),
      cancelToken: cancelToken,
    );
  }

  /// Turns a non-challenge HTTP error status back into a network
  /// failure so [_requestWithRetry] moves on to the next mirror (and
  /// the caller never treats e.g. a 404 or a plain "link expired" 403
  /// as an empty-but-successful result).
  void _ensureResponseStatus(Response<dynamic> response, String url) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    _logger.warning('Anna\'s Archive returned an error status',
        tag: 'AnnasArchive',
        metadata: {
          'status': status,
          'url': url,
          'length': response.data?.toString().length ?? 0
        });
    throw DioException.badResponse(
      statusCode: status,
      requestOptions: response.requestOptions,
      response: response,
    );
  }

  /// Reads [url]'s solve cache and only returns HTML that is actually a
  /// usable page. The solver's capture check keys on the <title>, so a
  /// DDoS-Guard interstitial whose title already names the site can slip
  /// into the cache; parsing that page would produce a silent "empty
  /// result" for the next 10 minutes (booklist_solver.dart fixed the
  /// same issue with a comment: "a stale challenge page must not
  /// short-circuit the solve"). Returns null when absent or stale.
  String? _usableCachedHtml(String url) {
    final cached = ChallengeHtmlCache.get(url);
    if (cached == null) return null;
    if (WebviewChallengeSolver.isChallengeHtml(cached)) {
      _logger.warning('Ignoring cached challenge HTML for $url',
          tag: 'AnnasArchive');
      return null;
    }
    return cached;
  }

  /// True when trying Dio first is pointless for this call: the enabled
  /// mirror list is non-empty, but every mirror in it sits behind a bot
  /// challenge. Dio requests to a protected mirror either time out
  /// (DDoS-Guard drops non-browser clients without answering) or come
  /// back as a challenge page, so the Dio phase only burns the 8s
  /// timeout on each mirror before the WebView solve runs. An empty list
  /// returns false — that is the no-mirror error, which
  /// [_requestWithRetry] already reports.
  Future<bool> _shouldSkipDio() async {
    final urls =
        await _instanceManager.enabledUrls(MirrorService.annasArchive);
    if (urls.isEmpty) return false;
    return !await _instanceManager
        .hasUnprotectedMirror(MirrorService.annasArchive);
  }
}
