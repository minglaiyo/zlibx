part of 'annas_archieve.dart';

/// Search-side cluster: URL building, the parser, the WebView solve
/// fallback and the public searchBooks API.
mixin _AnnasSearchMixin on _AnnasClientMixin {
  // --------------------------------------------------------------------
  // _parser FUNCTION (Search Results - Fixed nth-of-type issue)
  // --------------------------------------------------------------------
  // Async since phase 4: the parse routes through the Rust bridge when
  // injected (the Dart implementation stays as the fallback). All five
  // call sites already run in async contexts, so the Future wrapper is
  // behavior-neutral.
  Future<List<BookData>> _parser(
    dynamic resData,
    String fileType,
    String currentBaseUrl,
  ) async {
    final parsed = await ArchiveParsing.parseSearchResultsH(
      resData.toString(),
      baseUrl: currentBaseUrl,
      fileType: fileType,
    );
    _logger.info(
      'Parser completed',
      tag: 'AnnasArchive',
      metadata: {'booksFound': parsed.length},
    );
    return [
      for (final book in parsed)
        BookData(
          title: book.title,
          author: book.author,
          // The parser returns the raw img src, which is often a relative
          // path; resolve it against the mirror so the cover actually
          // loads in the card/hero. No-op when it is already absolute.
          thumbnail: book.thumbnail == null
              ? null
              : ArchiveParsing.resolveUrl(currentBaseUrl, book.thumbnail!),
          link: book.link,
          md5: book.md5,
          publisher: book.publisher,
          info: book.info,
        ),
    ];
  }

  String urlEncoder({
    required String searchQuery,
    required String content,
    required String sort,
    required String fileType,
    required String language,
    required String year,
    String author = "",
    String publisher = "",
    required bool enableFilters,
    required String currentBaseUrl,
    int page = 1,
  }) {
    return ArchiveParsing.buildSearchUrl(
      baseUrl: currentBaseUrl,
      query: searchQuery,
      content: content,
      sort: sort,
      fileType: fileType,
      language: language,
      year: year,
      author: author,
      publisher: publisher,
      enableFilters: enableFilters,
      page: page,
    );
  }

  /// WebView fallback for a search whose Dio attempts all failed without a
  /// response (timeout / connection killed — the DDoS-Guard signature when
  /// it drops non-browser clients). Builds the search URL for the first
  /// (easiest) mirror and solves it in a real browser engine. Returns the
  /// parsed books, or null when the solve failed or the user backed out.
  Future<List<BookData>?> _solveSearchViaWebView({
    required String searchQuery,
    required String content,
    required String sort,
    required String fileType,
    required String language,
    required String year,
    required String author,
    required String publisher,
    required bool enableFilters,
    required int page,
  }) async {
    final urls = await _instanceManager.enabledUrls(MirrorService.annasArchive);
    if (urls.isEmpty) return null;
    final baseUrl = urls.first;
    final targetUrl = urlEncoder(
      searchQuery: searchQuery,
      content: content,
      sort: sort,
      fileType: fileType,
      language: language,
      year: year,
      author: author,
      publisher: publisher,
      enableFilters: enableFilters,
      currentBaseUrl: baseUrl,
      page: page,
    );
    // A previous solve already captured this exact page: parse it
    // directly instead of solving again. (The Dio path checks this same
    // cache first; skipping Dio must not lose the instant repeat search.)
    final cached = _usableCachedHtml(targetUrl);
    if (cached != null) {
      _logger.info(
        'Using cached challenge HTML for search',
        tag: 'AnnasArchive',
        metadata: {'url': targetUrl},
      );
      return await _parser(cached, fileType, baseUrl);
    }
    _logger.info(
      'All mirrors timed out, solving search URL in WebView',
      tag: 'AnnasArchive',
      metadata: {'url': targetUrl},
    );
    final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(
      targetUrl,
    );
    if (html == null || html.length <= AnnasArchieve.minUsableHtmlLength) {
      _logger.warning(
        'WebView solve returned no usable HTML for search',
        tag: 'AnnasArchive',
      );
      return null;
    }
    return await _parser(html, fileType, baseUrl);
  }

  Future<List<BookData>> searchBooks({
    required String searchQuery,
    String content = "",
    String sort = "",
    String fileType = "",
    String language = "",
    String year = "",
    String author = "",
    String publisher = "",
    bool enableFilters = true,
    int page = 1,
  }) async {
    _logger.info(
      'Searching books',
      tag: 'AnnasArchive',
      metadata: {
        'query': searchQuery,
        'content': content,
        'sort': sort,
        'fileType': fileType,
        'language': language,
        'year': year,
        'author': author,
        'publisher': publisher,
        'filtersEnabled': enableFilters,
      },
    );

    // Fast path: every enabled mirror is protected, so Dio cannot
    // succeed — skip the timed-out Dio phase and solve the first
    // mirror's search URL in a WebView directly. If the solve fails
    // (solver unavailable / user backed out), surface the same timeout
    // error the Dio path would have produced instead of falling
    // through: falling through would burn the 8s timeout on every
    // mirror and then solve a second time in the catch below. This
    // check sits before the try on purpose, so the thrown error is not
    // re-caught by the fallback below.
    if (await _shouldSkipDio()) {
      try {
        final solved = await _solveSearchViaWebView(
          searchQuery: searchQuery,
          content: content,
          sort: sort,
          fileType: fileType,
          language: language,
          year: year,
          author: author,
          publisher: publisher,
          enableFilters: enableFilters,
          page: page,
        );
        if (solved != null) return solved;
      } catch (e) {
        _logger.error(
          'WebView pre-solve failed',
          tag: 'AnnasArchive',
          error: e.toString(),
        );
      }
      throw await _handleErrorAsync(
        TimeoutException('All mirrors protected and WebView solve failed'),
      );
    }

    try {
      final books = await _requestWithRetry<List<BookData>>((
        currentBaseUrl,
        cancelToken,
      ) async {
        final String encodedURL = urlEncoder(
          searchQuery: searchQuery,
          content: content,
          sort: sort,
          fileType: fileType,
          language: language,
          year: year,
          author: author,
          publisher: publisher,
          enableFilters: enableFilters,
          currentBaseUrl: currentBaseUrl,
          page: page,
        );

        // If the challenge solver already captured this page in a browser,
        // use it directly - Dio can never pass the challenge itself.
        // _usableCachedHtml rejects stale challenge interstitials.
        final cached = _usableCachedHtml(encodedURL);
        if (cached != null) {
          _logger.info(
            'Using cached challenge HTML for search',
            tag: 'AnnasArchive',
            metadata: {'url': encodedURL},
          );
          return await _parser(cached, fileType, currentBaseUrl);
        }

        _logger.debug(
          'Fetching search results',
          tag: 'AnnasArchive',
          metadata: {'url': encodedURL},
        );
        final response = await _makeRequest(
          encodedURL,
          cancelToken: cancelToken,
        );

        // Log response details for debugging
        _logger.debug(
          'Search response received',
          tag: 'AnnasArchive',
          metadata: {
            'statusCode': response.statusCode,
            'contentType': response.headers.value('content-type'),
            'responseLength': response.data?.toString().length ?? 0,
          },
        );

        // Check for Cloudflare block in the response
        if (_isChallengeResponse(response)) {
          _logger.warning(
            'Cloudflare/DDoS block detected in search response',
            tag: 'AnnasArchive',
          );
          throw NetworkError(
            type: NetworkErrorType.cloudflareBlock,
            userMessage: "Access blocked by DDoS protection",
            solution:
                "This site is protected and blocking your access.\n\n🔧 Solutions to try:\n• Use a VPN (recommended)\n• Change your DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network\n• Wait a few minutes and retry\n• Click 'Verify in Browser' to solve the captcha manually",
            technicalDetails: "DDoS challenge detected in response",
            rawResponseBody: response.data?.toString(),
            blockedUrl: encodedURL,
          );
        }

        // Not a challenge: a real error status (404, a plain "link
        // expired" 403, 5xx) must fail this attempt instead of parsing
        // into a silently-empty book list.
        _ensureResponseStatus(response, encodedURL);

        // A 200 from a host that is not Anna's Archive at all (SLUM
        // lists software.annas-archive.gl, a GitLab) must fail this
        // mirror too. Otherwise its unrelated markup parses to zero
        // books and the walk stops, reporting "no results" while the
        // mirrors that would have answered are never tried.
        if (!_isAnnasArchivePage(response.data.toString())) {
          _logger.warning(
            'Mirror did not serve an Anna\'s Archive page',
            tag: 'AnnasArchive',
            metadata: {'url': encodedURL, 'mirror': currentBaseUrl},
          );
          throw Exception(
            'Mirror $currentBaseUrl did not serve an Anna\'s Archive page',
          );
        }
        return await _parser(response.data, fileType, currentBaseUrl);
      });

      _logger.info(
        'Search completed',
        tag: 'AnnasArchive',
        metadata: {'results': books.length},
      );
      return books;
    } on NetworkError catch (networkErr) {
      // All mirrors are challenge-blocked. Let a real browser solve the
      // challenge and capture the page, then parse it directly. The captured
      // HTML is cached by URL, so a retry ("Try Again") parses it instantly.
      if (networkErr.type == NetworkErrorType.cloudflareBlock &&
          WebviewChallengeSolver.isSupported &&
          networkErr.blockedUrl != null) {
        _logger.info(
          'Attempting automatic challenge solve via webview',
          tag: 'AnnasArchive',
        );

        try {
          final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(
            networkErr.blockedUrl!,
          );
          if (html != null && html.length > AnnasArchieve.minUsableHtmlLength) {
            _logger.info(
              'Challenge solved, parsing results from webview HTML',
              tag: 'AnnasArchive',
            );
            // Uri.parse(...).origin throws on non-http(s) schemes, and the
            // solver itself can fail: a crash here must escape as the
            // original NetworkError, not as a bare StateError that
            // violates the "searchBooks only throws NetworkError"
            // contract.
            final currentBaseUrl = Uri.parse(networkErr.blockedUrl!).origin;
            return await _parser(html, fileType, currentBaseUrl);
          } else {
            _logger.warning(
              'Webview solver returned no usable HTML',
              tag: 'AnnasArchive',
            );
          }
        } catch (solveError, solveStack) {
          _logger.error(
            'Challenge solve crashed; reporting the original '
            'block instead',
            tag: 'AnnasArchive',
            error: solveError,
            stackTrace: solveStack,
          );
        }
      }
      // Dio never got a response at all: every mirror timed out (DDoS-Guard
      // drops non-browser connections without serving a challenge page, so
      // there is no cloudflareBlock to catch — the device-verified Stage 1
      // failure). Solve the first mirror's search URL in a real browser
      // engine instead. A longer Dio timeout would only fail slower: a
      // dropped connection never answers.
      if ((networkErr.type == NetworkErrorType.timeout ||
              networkErr.type == NetworkErrorType.serverUnavailable) &&
          WebviewChallengeSolver.isSupported) {
        try {
          final solved = await _solveSearchViaWebView(
            searchQuery: searchQuery,
            content: content,
            sort: sort,
            fileType: fileType,
            language: language,
            year: year,
            author: author,
            publisher: publisher,
            enableFilters: enableFilters,
            page: page,
          );
          if (solved != null) return solved;
        } catch (solveError, solveStack) {
          _logger.error(
            'WebView search fallback crashed; rethrowing the '
            'original network error',
            tag: 'AnnasArchive',
            error: solveError,
            stackTrace: solveStack,
          );
        }
      }
      // Re-throw NetworkError as-is for UI to handle if solver failed or unavailable
      rethrow;
    } on DioException catch (e) {
      _logger.error(
        'Search failed',
        tag: 'AnnasArchive',
        error: e.message ?? e.error,
      );
      throw await _handleErrorAsync(
        e,
        responseBody: e.response?.data?.toString(),
      );
    } catch (e) {
      _logger.error(
        'Unexpected search error',
        tag: 'AnnasArchive',
        error: e.toString(),
      );
      throw await _handleErrorAsync(e);
    }
  }
}
