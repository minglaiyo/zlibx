part of 'annas_archieve.dart';

/// Detail-page cluster: the parser, the WebView solve fallback and the
/// public bookInfo API.
mixin _AnnasBookInfoMixin on _AnnasClientMixin {
  // --------------------------------------------------------------------
  // _bookInfoParser FUNCTION (Detail Page - Fixed 'unable to get data' error)
  // --------------------------------------------------------------------
  Future<BookInfoData?> _bookInfoParser(
      dynamic resData, String url, String currentBaseUrl) async {
    final details = ArchiveParsing.parseBookDetails(
      resData.toString(),
      url: url,
      baseUrl: currentBaseUrl,
    );
    if (details == null) return null;
    return BookInfoData(
      title: details.title,
      author: details.author,
      // Same relative-path fix as the search parser: resolve the cover
      // against the mirror so the hero image loads.
      thumbnail: details.thumbnail == null
          ? null
          : ArchiveParsing.resolveUrl(currentBaseUrl, details.thumbnail!),
      publisher: details.publisher,
      info: details.info,
      link: details.link,
      md5: details.md5,
      format: details.format,
      mirror: details.slowDownloadUrl,
      description: details.description,
    );
  }

  /// WebView fallback for a bookInfo whose Dio attempts all failed without
  /// a response. Solves the detail URL (re-hosted onto the first mirror,
  /// same replacement the request closure does) in a real browser engine.
  /// Returns the parsed details, or null when the solve failed or the
  /// user backed out.
  Future<BookInfoData?> _solveBookInfoViaWebView(String url) async {
    final urls =
        await _instanceManager.enabledUrls(MirrorService.annasArchive);
    if (urls.isEmpty) return null;
    final baseUrl = urls.first;
    final urlParsed = Uri.parse(url);
    final currentParsed = Uri.parse(baseUrl);
    var adjustedUrl = url;
    if (urlParsed.host != currentParsed.host) {
      adjustedUrl =
          '$baseUrl${urlParsed.path}${urlParsed.query.isNotEmpty ? "?${urlParsed.query}" : ""}';
    }
    // Same cache fast-path as the Dio closure: a previous solve already
    // captured this exact detail page.
    final cached = _usableCachedHtml(adjustedUrl);
    if (cached != null) {
      _logger.info('Using cached challenge HTML for bookInfo',
          tag: 'AnnasArchive', metadata: {'url': adjustedUrl});
      return _bookInfoParser(cached, adjustedUrl, baseUrl);
    }
    _logger.info('All mirrors timed out, solving book URL in WebView',
        tag: 'AnnasArchive', metadata: {'url': adjustedUrl});
    final html =
        await WebviewChallengeSolver.fetchHtmlAfterChallenge(adjustedUrl);
    if (html == null || html.length <= AnnasArchieve.minUsableHtmlLength) {
      _logger.warning('WebView solve returned no usable HTML for bookInfo',
          tag: 'AnnasArchive');
      return null;
    }
    return _bookInfoParser(html, adjustedUrl, baseUrl);
  }

  Future<BookInfoData> bookInfo(
      {required String url, String? donationKey}) async {
    _logger.info('Fetching book info',
        tag: 'AnnasArchive', metadata: {'url': url});

    // Fast path, same as searchBooks: every enabled mirror is protected,
    // so skip the timed-out Dio phase and solve this book's detail URL
    // (on the first mirror) in a WebView directly.
    if (await _shouldSkipDio()) {
      try {
        final solved = await _solveBookInfoViaWebView(url);
        if (solved != null) return solved;
      } catch (e) {
        _logger.error('WebView pre-solve failed',
            tag: 'AnnasArchive', error: e.toString());
      }
      throw await _handleErrorAsync(
        TimeoutException('All mirrors protected and WebView solve failed'),
      );
    }

    try {
      final data =
          await _requestWithRetry<BookInfoData>((currentBaseUrl, cancelToken) async {
        // Replace the base URL in the url parameter if it contains a different one
        String adjustedUrl = url;
        final urlParsed = Uri.parse(url);
        final currentParsed = Uri.parse(currentBaseUrl);

        // If the URL has a different host, replace it with current instance's host
        if (urlParsed.host != currentParsed.host) {
          adjustedUrl =
              '$currentBaseUrl${urlParsed.path}${urlParsed.query.isNotEmpty ? "?${urlParsed.query}" : ""}';
        }

        // If the challenge solver already captured this page in a browser,
        // use it directly - Dio can never pass the challenge itself.
        // _usableCachedHtml rejects stale challenge interstitials.
        final cached = _usableCachedHtml(adjustedUrl);
        if (cached != null) {
          _logger.info('Using cached challenge HTML for bookInfo',
              tag: 'AnnasArchive', metadata: {'url': adjustedUrl});
          final data =
              await _bookInfoParser(cached, adjustedUrl, currentBaseUrl);
          if (data != null) return data;
        }

        _logger.debug('Fetching book details',
            tag: 'AnnasArchive', metadata: {'url': adjustedUrl});
        final response =
            await _makeRequest(adjustedUrl, cancelToken: cancelToken);

        // Check for Cloudflare block in the response
        if (_isChallengeResponse(response)) {
          _logger.warning(
              'Cloudflare/DDoS block detected in book info response',
              tag: 'AnnasArchive');
          throw NetworkError(
            type: NetworkErrorType.cloudflareBlock,
            userMessage: "Access blocked by DDoS protection",
            solution:
                "This site is protected and blocking your access.\n\n🔧 Solutions to try:\n• Use a VPN (recommended)\n• Change your DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network\n• Wait a few minutes and retry\n• Click 'Verify in Browser' to solve the captcha manually",
            technicalDetails: "DDoS challenge detected in response",
            rawResponseBody: response.data?.toString(),
            blockedUrl: adjustedUrl,
          );
        }

        // Not a challenge: a real error status must fail this attempt
        // rather than be parsed into a null (handled below) or an
        // error page mistaken for book details.
        _ensureResponseStatus(response, adjustedUrl);
        final BookInfoData? data =
            await _bookInfoParser(response.data, adjustedUrl, currentBaseUrl);
        if (data != null) {
          return data;
        } else {
          // Log response preview when parser fails
          final responseStr = response.data?.toString() ?? "";
          final preview = responseStr.substring(
              0, responseStr.length > 1000 ? 1000 : responseStr.length);
          _logger.error('Parser returned null - possible DDoS protection page',
              tag: 'AnnasArchive',
              metadata: {
                'url': adjustedUrl,
                'responseLength': responseStr.length,
                'statusCode': response.statusCode,
                'preview': preview,
              });

          throw NetworkError(
            type: NetworkErrorType.unknown,
            userMessage: "Unable to load book details",
            solution:
                "The book information could not be retrieved. Try again or try a different mirror in Settings.",
            technicalDetails: "Parser returned null for URL: $adjustedUrl",
            rawResponseBody: preview,
          );
        }
      });

      _logger.info('Book info retrieved successfully',
          tag: 'AnnasArchive',
          metadata: {
            'title': data.title,
            'format': data.format,
            'hasMirror': data.mirror != null,
          });
      return data;
    } on NetworkError catch (networkErr) {
      // If all instances failed with 403 and webview solver is available, try automatic solve.
      if (networkErr.type == NetworkErrorType.cloudflareBlock &&
          WebviewChallengeSolver.isSupported &&
          networkErr.blockedUrl != null) {
        _logger.info(
            'Attempting automatic challenge solve via webview for bookInfo',
            tag: 'AnnasArchive');

        try {
          final targetUrl = networkErr.blockedUrl!;
          final html =
              await WebviewChallengeSolver.fetchHtmlAfterChallenge(targetUrl);
          if (html != null && html.length > AnnasArchieve.minUsableHtmlLength) {
            _logger.info('Challenge solved, parsing bookInfo from webview HTML',
                tag: 'AnnasArchive');
            final currentBaseUrl = Uri.parse(targetUrl).origin;
            final data =
                await _bookInfoParser(html, targetUrl, currentBaseUrl);
            if (data != null) {
              return data;
            } else {
              // The page rendered fine but holds no book details - the md5
              // led to a search redirect. This is a dead link, not a block.
              _logger.warning('Webview HTML parsed but returned null bookInfo',
                  tag: 'AnnasArchive');
              throw NetworkError(
                type: NetworkErrorType.unknown,
                userMessage: "Book not found",
                solution:
                    "The page loaded but no book details were on it. The md5 link may be outdated - try searching for the title instead.",
                technicalDetails:
                    "Parser returned null for solved page: $targetUrl",
              );
            }
          } else {
            _logger.warning(
                'Webview solver returned no usable HTML for bookInfo',
                tag: 'AnnasArchive');
          }
        } catch (solveError, solveStack) {
          // A solver crash (bad URL scheme, UI callback failure, ...)
          // must not escape as a bare exception: surface the original
          // NetworkError so the UI's error handling keeps working.
          if (solveError is NetworkError) rethrow;
          _logger.error('Challenge solve crashed; reporting the original '
              'block instead',
          tag: 'AnnasArchive',
          error: solveError,
          stackTrace: solveStack);
        }
      }
      // Same timeout fallback as searchBooks: Dio got no response from any
      // mirror. Solve this book's detail URL (on the first mirror) in a
      // real browser engine instead.
      if ((networkErr.type == NetworkErrorType.timeout ||
              networkErr.type == NetworkErrorType.serverUnavailable) &&
          WebviewChallengeSolver.isSupported) {
        try {
          final solved = await _solveBookInfoViaWebView(url);
          if (solved != null) return solved;
        } catch (solveError, solveStack) {
          if (solveError is NetworkError) rethrow;
          _logger.error('WebView bookInfo fallback crashed; rethrowing the '
              'original network error',
          tag: 'AnnasArchive',
          error: solveError,
          stackTrace: solveStack);
        }
      }
      // Re-throw NetworkError as-is for UI to handle if solver failed or unavailable
      rethrow;
    } on DioException catch (e) {
      _logger.error('Failed to fetch book info',
          tag: 'AnnasArchive', error: e.message ?? e.error);
      throw await _handleErrorAsync(e,
          responseBody: e.response?.data?.toString());
    } catch (e) {
      _logger.error('Unexpected book info error',
          tag: 'AnnasArchive', error: e.toString());
      throw await _handleErrorAsync(e);
    }
  }
}
