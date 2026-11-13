// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/mirror_fetcher.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
//
// Android-only adaptation: upstream's Linux early-return
// (`PlatformUtils.isLinux` → return []) is deleted — zlibx builds
// Android only and never takes that branch.

// Dart imports:
import 'dart:async';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';

/// Service to fetch mirror links in the background without showing UI
class MirrorFetcherService {
  /// Total wait budget for one fetch. The Anna slow_download page shows
  /// a countdown first and releases its direct link only after it —
  /// later than onLoadStop — so the link extraction polls within this
  /// budget instead of reading the page once. Provisional 30s: the
  /// lower end of the 30-60s window the countdown can take; re-tune
  /// after measuring the real countdown on a device.
  static const Duration slowLinkWaitTimeout = Duration(seconds: 30);

  /// Cadence of the slow_download link re-check while waiting.
  static const Duration slowLinkPollInterval = Duration(seconds: 1);

  static final MirrorFetcherService _instance = MirrorFetcherService._internal();
  factory MirrorFetcherService() => _instance;
  MirrorFetcherService._internal();

  final AppLogger _logger = AppLogger();

  /// Links scraped out of a page (JS `a.href` / extracted download
  /// anchors) must be absolute https: page-injected `javascript:` /
  /// `data:` hrefs and non-string engine quirks (a `null` entry would
  /// make `cast<String>()` throw on first use) are dropped here.
  static bool _isUsableLink(Object? href) {
    if (href is! String || href.isEmpty) return false;
    final uri = Uri.tryParse(href);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  /// Fetch mirror links from the given URL in the background
  /// Returns a list of mirror download links
  Future<List<String>> fetchMirrors(String url) async {
    _logger.info('Starting background mirror fetch', tag: 'MirrorFetcher', metadata: {'url': url});

    final Completer<List<String>> completer = Completer<List<String>>();
    final List<String> bookDownloadLinks = [];

    HeadlessInAppWebView? headlessWebView;
    try {
      // Create a headless webview to load the page
      final webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        onLoadStop: (controller, url) async {
          if (url == null) {
            _logger.warning('URL is null in onLoadStop', tag: 'MirrorFetcher');
            if (!completer.isCompleted) {
              completer.complete([]);
            }
            return;
          }

          _logger.debug('Page loaded successfully', tag: 'MirrorFetcher', metadata: {'url': url.toString()});

          // A challenge interstitial is ALSO a "page load": completing
          // here used to extract 0 links from the challenge page (or throw
          // in the slow_download branch) and fail instantly on every
          // protected mirror — the exact opposite of this service's job.
          // Detect it and keep waiting: the challenge auto-solves and
          // redirects, firing another onLoadStop with the real page. The
          // outer timeout below (slowLinkWaitTimeout) still bounds the
          // whole wait.
          try {
            final title = await controller.getTitle() ?? '';
            final bodySnippet = await controller.evaluateJavascript(
                  source:
                      "document.body ? document.body.innerText.substring(0, 1500) : '';",
                );
            final snippet = bodySnippet?.toString() ?? '';
            if (WebviewChallengeSolver.isChallengePage(
              title: title,
              bodySnippet: snippet,
            )) {
              _logger.info('Challenge page detected, waiting for the '
                      'auto-solve redirect',
                  tag: 'MirrorFetcher',
                  metadata: {'url': url.toString()});
              return;
            }
          } catch (challengeCheckError) {
            // Title/JS probing failed — fall through and try link
            // extraction anyway; it has its own error handling.
            _logger.debug('Challenge probe failed, continuing with '
                    'extraction',
                tag: 'MirrorFetcher');
          }

          try {
            if (url.toString().contains("slow_download")) {
              // The slow_download page shows a countdown first and
              // releases the direct link only after it — later than
              // onLoadStop — so a single extraction here usually finds
              // nothing and the flow used to fall to the unprotected
              // plain-HTML fallback. Poll with the same selector once
              // per second until the link appears or the outer timeout
              // bounds the wait (same selector as Route 4's
              // extractSlowDownloadLink in lib/core/annas_archive.dart).
              String query =
                  """var paragraphTag=document.querySelector('p[class="mb-4 text-xl font-bold"]');var anchorTagHref=paragraphTag.querySelector('a').href;var url=()=>{return anchorTagHref};url();""";
              while (!completer.isCompleted) {
                String? mirrorLink;
                try {
                  mirrorLink =
                      await controller.evaluateJavascript(source: query);
                } catch (pollError) {
                  // The selector throws while the countdown paragraph is
                  // absent: "not ready yet", poll again.
                  _logger.debug('slow_download link not ready yet',
                      tag: 'MirrorFetcher',
                      metadata: {'error': pollError.toString()});
                }
                if (mirrorLink != null && mirrorLink.isNotEmpty) {
                  if (_isUsableLink(mirrorLink)) {
                    bookDownloadLinks.add(mirrorLink);
                    _logger.info('Extracted slow_download link', tag: 'MirrorFetcher');
                  } else {
                    _logger.warning('slow_download link failed the '
                            'https/host check, dropped',
                        tag: 'MirrorFetcher',
                        metadata: {'link': mirrorLink});
                  }
                  break;
                }
                await Future<void>.delayed(slowLinkPollInterval);
              }
            } else {
              // For other mirror pages, extract all IPFS/mirror links
              String query =
                  """Array.from(document.querySelectorAll('ul>li>a')).map(e=>e.href).filter(Boolean);""";
              List<dynamic> mirrorLinks =
                  await controller.evaluateJavascript(source: query);
              bookDownloadLinks
                  .addAll(mirrorLinks.where(_isUsableLink).cast<String>());
              _logger.info('Extracted mirror links', tag: 'MirrorFetcher', metadata: {'count': bookDownloadLinks.length});
            }

            // Complete the future with the extracted links
            if (!completer.isCompleted) {
              completer.complete(bookDownloadLinks);
            }
          } catch (e) {
            _logger.error('JavaScript evaluation error', tag: 'MirrorFetcher', error: e);
            // Evaluation error, complete with empty list
            if (!completer.isCompleted) {
              completer.complete([]);
            }
          }
        },
        onReceivedError: (controller, request, error) {
          // Only a MAIN-FRAME error means the page is unavailable.
          // favicon / image / analytics 404s used to kill the whole
          // extraction even though the document itself loaded fine.
          if (request.isForMainFrame != true) {
            _logger.debug('Sub-resource load error (ignored)',
                tag: 'MirrorFetcher');
            return;
          }
          _logger.error('WebView load error', tag: 'MirrorFetcher', error: error.description);
          // Load error, complete with empty list
          if (!completer.isCompleted) {
            completer.complete([]);
          }
        },
      );

      headlessWebView = webView;
      // Run the headless webview
      await webView.run();
      _logger.debug('Headless webview started', tag: 'MirrorFetcher');

      // Wait for the page to load and links to be extracted; the
      // slow_download poll above keeps waiting within this budget.
      final result = await completer.future.timeout(
        slowLinkWaitTimeout,
        onTimeout: () {
          _logger.warning(
              'Mirror fetch timed out after '
              '${slowLinkWaitTimeout.inSeconds} seconds',
              tag: 'MirrorFetcher');
          // Release the poll loop: it stops at its next check instead
          // of lingering after this future has already resolved.
          if (!completer.isCompleted) {
            completer.complete([]);
          }
          return [];
        },
      );

      _logger.debug('Headless webview completed', tag: 'MirrorFetcher', metadata: {'mirrors_found': result.length});
      return result;
    } catch (e, stackTrace) {
      _logger.error('Failed to fetch mirrors', tag: 'MirrorFetcher', error: e, stackTrace: stackTrace);
      return [];
    } finally {
      try {
        await headlessWebView?.dispose();
        _logger.debug('Headless webview disposed', tag: 'MirrorFetcher');
      } catch (disposeError) {
        _logger.warning('Headless webview dispose failed', tag: 'MirrorFetcher', error: disposeError);
      }
    }
  }
}
