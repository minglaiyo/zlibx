// Anna's Archive source: models live in annas_models.dart, and the
// request / search / detail method clusters live in the part files below.
// Dart cannot split one class body across parts, so each part declares a
// private mixin; AnnasArchieve applies them in order, keeping every public
// member and signature on the class itself.
// Dart imports:
import 'dart:async';
import 'dart:convert';

// Package imports:
import 'package:dio/dio.dart';

// Project imports:
import 'package:zlibx/core/annas_archive.dart';
import 'package:zlibx/services/challenge_html_cache.dart';
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/http_client.dart';
import 'package:zlibx/services/instance_manager.dart';
import 'package:zlibx/services/network_error.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';
import 'package:zlibx/utils/host_utils.dart';

import 'annas_models.dart';

export 'annas_models.dart';

part 'annas_client.dart';
part 'annas_search.dart';
part 'annas_book_info.dart';

/// Shared state for the AnnasArchieve mixins below. The public class
/// applies them in order; Dart cannot split one class body across part
/// files, so the mixins carry the method clusters instead.
abstract class _AnnasArchieveBase {
  Dio get dio;
  InstanceManager get _instanceManager;
  AppLogger get _logger;
  Map<String, dynamic> get defaultDioHeaders;

  // True when a response is a bot-protection interstitial rather than the
  // page we asked for.
  //
  // Two families of signal:
  //  * Cloudflare's own `cf-mitigated: challenge` header - conclusive;
  //  * the interstitials' own text. Markers that also occur on ordinary
  //    pages ("cloudflare", "please wait") only count on a status code a
  //    challenge actually uses (403/503), so a real search result page
  //    that happens to mention Cloudflare is not mistaken for a block.
  bool _isChallengeResponse(Response response) {
    final blocked = ArchiveParsing.isChallengeResponse(
      statusCode: response.statusCode ?? 0,
      cfMitigated: response.headers.value('cf-mitigated'),
      body: response.data?.toString() ?? '',
    );
    if (blocked) {
      _logger.warning('DDoS protection detected',
          tag: 'AnnasArchive', metadata: {'statusCode': response.statusCode});
    }
    return blocked;
  }

  /// True when [html] is an Anna's Archive document rather than some other
  /// site that answers on the same host.
  ///
  /// open-slum.org lists a few non-search hosts on its annas page - most
  /// importantly `software.annas-archive.gl`, which serves a GitLab instance.
  /// It answers `/search` with a 200 and unrelated markup, so the search
  /// parser finds nothing and the provider used to accept that as a real
  /// "no results" answer and stop, hiding the mirrors that would have
  /// worked. Every Anna's Archive page carries "Anna's Archive" in its
  /// title; a page that does not is the wrong page, not an empty result.
  bool _isAnnasArchivePage(String html) => ArchiveParsing.isArchivePage(html);
}

class AnnasArchieve extends _AnnasArchieveBase
    with _AnnasClientMixin, _AnnasSearchMixin, _AnnasBookInfoMixin {
  AnnasArchieve({Dio? dio, InstanceManager? instanceManager})
      : dio = dio ?? createDio(),
        _instanceManager = instanceManager ?? InstanceManager();

  @override
  final Dio dio;

  @override
  final InstanceManager _instanceManager;

  @override
  final AppLogger _logger = AppLogger();

  /// A WebView-captured page below this size never holds a usable
  /// search/detail result (an empty shell or a redirect stub). A size
  /// check alone is not enough — it is always paired with
  /// [WebviewChallengeSolver.isChallengeHtml], see [_usableCachedHtml].
  static const int minUsableHtmlLength = 1000;

  // Optimized retry settings for faster response
  static const int maxRetriesPerInstance =
      1; // Only 1 retry per instance for speed
  static const int requestTimeoutSeconds = 8; // Timeout for the first mirror
  // Later mirrors get half the timeout, halved once (never less): a live
  // mirror usually answers in seconds, a dead one just burns the budget.
  static const int subsequentRequestTimeoutSeconds = 4;
  static const int retryDelayMs = 200; // Shorter delay between retries

  @override
  Map<String, dynamic> defaultDioHeaders = {
    "user-agent":
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "accept":
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "accept-language": "en-US,en;q=0.9",
    "sec-ch-ua":
        '"Chromium";v="122", "Not(A:Brand";v="24", "Google Chrome";v="122"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Linux"',
    "sec-fetch-dest": "document",
    "sec-fetch-mode": "navigate",
    "sec-fetch-site": "none",
    "sec-fetch-user": "?1",
    "upgrade-insecure-requests": "1",
  };

  /// Fast download URL for [md5] using the user's donation [key].
  ///
  /// S1: the key is only ever sent to a confirmed Anna's Archive search
  /// host ([isAnnasFamilyHost]), and only ONCE. Unlike the search path
  /// ([_requestWithRetry]), this does NOT retry across mirrors: a failure
  /// returns null and the caller falls back to slow download, so the key
  /// never reaches a second host. The returned link must be https.
  /// Errors are logged by exception TYPE only — never the message — so
  /// the request URI (which carries `key=`) can never reach a log line.
  Future<String?> getFastDownloadUrl(String md5, String key) async {
    _logger.info('Fetching fast download URL',
        tag: 'AnnasArchive', metadata: {'md5': md5});

    // md5 is a 32-char lowercase hex digest; anything else is not a
    // book id and must never reach the URL.
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(md5)) {
      _logger.warning(
          'Refusing fast download: md5 is not a 32-char hex digest',
          tag: 'AnnasArchive');
      return null;
    }
    // Only whitelisted search hosts may receive the key. The list comes
    // from open-slum.org (untrusted input), so filter it — an unlisted
    // host fails closed.
    final urls =
        await _instanceManager.enabledUrls(MirrorService.annasArchive);
    final trusted = urls
        .where((u) => isAnnasFamilyHost(Uri.tryParse(u)?.host ?? ''))
        .toList();
    if (trusted.isEmpty) {
      _logger.warning('No trusted Anna search host for fast download',
          tag: 'AnnasArchive');
      return null;
    }
    // Single attempt against the first trusted mirror (enabledUrls is
    // best-first). A failure does NOT move on to the next mirror.
    final baseUrl = trusted.first;
    try {
      // The key is URL-encoded: it is user input and must never be
      // pasted raw into a query string.
      final fastDownloadUrl =
          '$baseUrl/dyn/api/fast_download.json?md5=$md5&key=${Uri.encodeQueryComponent(key)}';
      // Log only the md5, never the URL: it carries the donation key.
      _logger.debug('Calling fast download API',
          tag: 'AnnasArchive', metadata: {'md5': md5});

      final cancelToken = CancelToken();
      final response = await dio
          .get(fastDownloadUrl,
              options: Options(headers: defaultDioHeaders),
              cancelToken: cancelToken)
          .timeout(
        const Duration(seconds: AnnasArchieve.requestTimeoutSeconds),
        onTimeout: () {
          cancelToken.cancel();
          throw TimeoutException(
              'Request timed out after ${AnnasArchieve.requestTimeoutSeconds}s');
        },
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        dynamic data = response.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } catch (e) {
            _logger.warning('Failed to parse fast download JSON response',
                tag: 'AnnasArchive', error: e.runtimeType.toString());
            throw Exception('Invalid JSON response');
          }
        }

        if (data is Map && data['download_url'] != null) {
          final link = data['download_url'].toString();
          // The returned link must be https; a non-https (or
          // unparseable) link is not a download URL.
          final uri = Uri.tryParse(link);
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
            _logger.warning(
                'Fast download URL is not https, refusing it',
                tag: 'AnnasArchive');
            return null;
          }
          _logger.info('Fast download URL obtained', tag: 'AnnasArchive');
          return link;
        } else {
          final errorMsg = data is Map ? data['error'] : 'Unknown error';
          _logger.warning('Fast download URL not found in response',
              tag: 'AnnasArchive', metadata: {'error': errorMsg});
          throw Exception(errorMsg ?? 'Fast download URL not found');
        }
      } else {
        _logger.error('Fast download API request failed',
            tag: 'AnnasArchive', metadata: {'status': response.statusCode});
        throw Exception('Failed to get fast download URL');
      }
    } catch (e) {
      _logger.error('Failed to get fast download URL',
          tag: 'AnnasArchive', error: e.runtimeType.toString());
      return null;
    }
  }
}
