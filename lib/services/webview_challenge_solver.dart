// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/webview_challenge_solver.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
//
// Cross-platform DDoS-challenge solver.
//
// Anna's Archive is protected by DDoS-Guard. Its clearance cookies are HttpOnly
// AND bound to the browser context, so extracting them and replaying through Dio
// never works (that was the alpha's approach and it loops 403 forever). Instead
// we let a real browser engine pass the challenge and capture the fully rendered
// page HTML:
//
//   - Android/iOS: HeadlessInAppWebView runs invisible and automatic. If a real
//     human CAPTCHA appears, callers fall back to the visible solver page.
//
// Captured HTML is stored in ChallengeHtmlCache keyed by the request URL, so a
// retry ("Try Again") or another mirror attempt can parse it directly.
//
// Android-only adaptation notes (zlibx):
//  * The upstream desktop branch (the desktop window package import and
//    the visible desktop window solver) is DELETED — zlibx builds
//    Android only and that import breaks the build.
//  * `_js` uses flutter_inappwebview 6.x `evaluateJavascript(source: ...)`
//    (the upstream `_js` called the v5-spelled `evaluateJavaScript`,
//    which does not exist in v6).
//  * `InAppWebViewSettings` only uses options verified against v6.1.5
//    (upstream's `incognito` / `clearCache` are dropped; both default
//    to false anyway).

// Dart imports:
import 'package:zlibx/utils/diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

// Package imports:
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:zlibx/services/challenge_html_cache.dart';
import 'package:zlibx/services/webview_security.dart';
import 'package:zlibx/services/external_logger.dart';

/// 一次后台 WebView 跑完的两种产出。
///
/// 书页那条腿要 [html]（按钮就在渲染出来的页面里）。`/dl/{token}` 那条腿
/// 要的是 [fileUrl]（第 9 轮，2026-11-24 真机第 7 份报告）：那一跳过了墙
/// 之后交出来的是文件，浏览器会被交予一个直链，而这个直链才是 Dio 能拿走
/// 的东西——「把墙 cookie 回灌进 Dio 再重发 `/dl/`」在真机上重发回来仍是
/// 校验页。两种产出共用同一发 WebView：cookie jar 照样被这一次求解填满。
class HeadlessSolveResult {
  const HeadlessSolveResult({
    this.html,
    this.fileUrl,
    this.fileSource = 'none',
    this.landedUrl,
  });

  final String? html;

  /// 浏览器在这一跳被交予的文件地址（https，见 [looksLikeFileUrl]）。
  final String? fileUrl;

  /// 这个地址是从哪儿认出来的：`download-start`（WebView 的下载回调，
  /// 最强证据）/ `landed-url`（浏览器最终停在的地址看着就是个文件）/
  /// `none`（没拿到）。写进失败文案，为了把「墙没过」和「过了墙但这一跳
  /// 根本不以文件收尾」分开。
  final String fileSource;

  /// 这一发 WebView 最后停在哪个地址（诊断用，未掩码——只进记录函数）。
  final String? landedUrl;

  bool get gotFileUrl => fileUrl != null && fileUrl!.isNotEmpty;
}

class WebviewChallengeSolver {
  WebviewChallengeSolver._();

  static final AppLogger _logger = AppLogger();

  /// 最近一次**成功抓回 HTML** 时 WebView 真正停在哪一页（诊断用）。
  /// 请求 `/book/{id}/{hash}/` 却被弹回首页，只有这里看得见。
  static String lastNavigatedUrl = '';

  /// Test seam for the platform check: when set, overrides the real
  /// platform check. Production never sets it.
  @visibleForTesting
  static bool? overrideIsSupported;

  /// Android/iOS use flutter_inappwebview. zlibx is Android-only, so
  /// there is no desktop branch here (upstream's desktop window import
  /// was deleted).
  static bool get isSupported =>
      overrideIsSupported ?? (Platform.isAndroid || Platform.isIOS);

  /// Escape hatch for tests and headless environments: when false, no real
  /// webview is opened (headless or desktop window) and the solve returns
  /// null — but a registered [visibleSolverFallback] is still consulted,
  /// so tests can exercise the fallback without any webview.
  static bool guiEnabled = true;

  /// When false (user turned "verify in background" off in settings), the
  /// headless attempt is skipped on mobile and the visible window runs
  /// straight away - some devices never finish an invisible webview.
  static bool headlessEnabled = true;

  /// UI hook: when a headless mobile solve fails, this is called so the app
  /// shell to push the visible solver page over the current screen. It
  /// returns the captured HTML (which we then cache) or null when the user
  /// backs out without solving. A callback keeps this service free of UI
  /// imports. Registered by the app shell at startup.
  static Future<String?> Function(String url)? visibleSolverFallback;

  /// Test seam for the mobile/desktop branch: when set, overrides the real
  /// platform check. Production never sets it.
  @visibleForTesting
  static bool? overrideIsMobile;

  static bool get _isMobile =>
      overrideIsMobile ?? (Platform.isAndroid || Platform.isIOS);

  /// Returns true when the given page looks like an unfinished DDoS protection
  /// challenge (DDoS-Guard or Cloudflare) instead of real content.
  static bool isChallengePage({
    required String title,
    required String bodySnippet,
  }) {
    final t = title.toLowerCase();
    final b = bodySnippet.toLowerCase();
    const titleMarkers = [
      'ddos-guard',
      'just a moment',
      'attention required',
      'checking your browser',
    ];
    const bodyMarkers = [
      'ddos-guard/js-challenge',
      'check.ddos-guard.net',
      'ddg-l10n-title',
      'cf-turnstile',
      'challenge-platform',
      'cf-browser-verification',
    ];
    return titleMarkers.any(t.contains) || bodyMarkers.any(b.contains);
  }

  /// One in-flight solve per URL. A search + its detail request failing
  /// at the same time used to launch TWO headless webviews for the same
  /// page (and could pop the visible fallback twice). Keyed by URL: a
  /// different URL must never receive this page's HTML.
  static final Map<String, Future<String?>> _inFlightSolves = {};

  /// Host → the WebView User-Agent that last cleared a wall for that
  /// host. Wall clearance cookies are commonly bound to the UA they
  /// were minted with (`cf_clearance`), so `bridgeWallCookies` replays
  /// this UA to the API layer together with the cookies. Kept per host
  /// for the app session; a re-solve overwrites the entry.
  static final Map<String, String> _wallUserAgents = {};

  /// The WebView UA captured for [pageUrl]'s host, or null when no
  /// solve has recorded one yet.
  static String? wallUserAgentFor(String pageUrl) {
    final host = Uri.tryParse(pageUrl)?.host ?? '';
    if (host.isEmpty) return null;
    return _wallUserAgents[host];
  }

  /// Records [pageUrl]'s host → WebView UA. Best effort: a read
  /// failure leaves no entry and the bridge keeps the old UA-only
  /// behaviour. Only https hosts are recorded.
  static Future<void> _rememberWallUserAgent(
    InAppWebViewController controller,
    String pageUrl,
  ) async {
    final uri = Uri.tryParse(pageUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
    try {
      final ua = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      if (ua == null) return;
      final s = ua.toString();
      if (s.isEmpty || s == 'null') return;
      _wallUserAgents[uri.host] = s;
    } catch (error) {
      logIgnored('webview_challenge_solver', error);
    }
  }

  /// Solves the challenge for [url] and returns the fully rendered page HTML,
  /// or null if the challenge could not be cleared within [timeout].
  ///
  /// Mobile runs a headless webview (default 60 s, fully automatic). The
  /// result is also stored in ChallengeHtmlCache.
  ///
  /// A headless failure falls back to [visibleSolverFallback] when it is
  /// registered (headless misses human CAPTCHAs and races like the
  /// loadStop/readyState one).
  static Future<String?> fetchHtmlAfterChallenge(
    String url, {
    Duration? timeout,
  }) {
    if (!isSupported) return Future<String?>.value();
    // Merge concurrent solves of the SAME url into one webview run.
    final existing = _inFlightSolves[url];
    if (existing != null) {
      _logger.debug(
        'Joining in-flight challenge solve',
        tag: 'ChallengeSolver',
        metadata: {'url': url},
      );
      return existing;
    }
    final future = _fetchHtmlAfterChallengeUncancelable(url, timeout);
    _inFlightSolves[url] = future;
    // Remove on completion — whenComplete returns a NEW future, so the
    // map entry must point at `future`, and unawaited cleanup keeps the
    // map bounded.
    unawaited(future.whenComplete(() => _inFlightSolves.remove(url)));
    return future;
  }

  static Future<String?> _fetchHtmlAfterChallengeUncancelable(
    String url,
    Duration? timeout,
  ) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 60);

    final tryHeadless = guiEnabled && headlessEnabled;
    var html = tryHeadless
        ? (await _solveHeadless(url, effectiveTimeout)).html
        : null;

    if (html == null && _isMobile && visibleSolverFallback != null) {
      _logger.info(
        'Headless solve failed, using visible fallback',
        tag: 'ChallengeSolver',
        metadata: {'url': url},
      );
      html = await visibleSolverFallback!(url);
    }

    if (html != null) {
      ChallengeHtmlCache.store(url, html);
    }
    return html;
  }

  /// Headless-only solve: runs the invisible webview and returns the
  /// captured HTML, or null. Unlike [fetchHtmlAfterChallenge] this
  /// never consults [visibleSolverFallback], so it is safe to call
  /// from background warm-up code where no visible challenge screen
  /// may appear. The result is also stored in ChallengeHtmlCache.
  /// Returns null immediately when the solver is disabled (see
  /// [guiEnabled] and [headlessEnabled]) or unsupported on this
  /// platform.
  static Future<String?> fetchHtmlHeadlessOnly(
    String url, {
    Duration? timeout,
  }) async {
    if (!isSupported || !guiEnabled || !headlessEnabled) return null;
    final html = (await _solveHeadless(
      url,
      timeout ?? const Duration(seconds: 60),
    )).html;
    if (html != null) {
      ChallengeHtmlCache.store(url, html);
    }
    return html;
  }

  /// `/dl/{token}` 那一跳专用（第 9 轮）：让浏览器去领这个文件，把它被
  /// 交予的地址带回来。判据不是 HTML（那一跳过了墙也不是页面），所以
  /// 求解循环等的是下载回调或一个看着就是文件的落地地址，等到就走；
  /// 等不到也照样把这一次 WebView 的产出交回去——cookie jar 在这一发里
  /// 已经被填过了，调用方仍值得回灌一次。
  ///
  /// headless：下载跑在后台任务池里，弹校验页等于劫持界面。
  static Future<HeadlessSolveResult> solveHeadlessForFileUrl(
    String url, {
    Duration? timeout,
  }) async {
    if (!isSupported || !guiEnabled || !headlessEnabled) {
      return const HeadlessSolveResult();
    }
    final result = await _solveHeadless(
      url,
      // 与其它腿同一个上限：这一发是用户在等的下载，不是后台预热。
      timeout ?? const Duration(seconds: 60),
      captureFileUrl: true,
    );
    final html = result.html;
    if (html != null && html.isNotEmpty) {
      ChallengeHtmlCache.store(url, html);
    }
    return result;
  }

  /// Visible-only solve: skips the headless webview entirely and runs
  /// [visibleSolverFallback] directly, returning the captured HTML or
  /// null when there is no fallback or the user backs out. Callers use
  /// this when the headless solve already returned HTML that turned out
  /// not to be the wanted page (a bare error page, or a wall page the
  /// headless check mistook for solved): the visible page lets the
  /// wall's JS finish where the user can watch it, instead of failing
  /// outright. The result is also stored in ChallengeHtmlCache.
  static Future<String?> fetchHtmlVisibleOnly(String url) async {
    if (!_isMobile || visibleSolverFallback == null) return null;
    final html = await visibleSolverFallback!(url);
    if (html != null) {
      ChallengeHtmlCache.store(url, html);
    }
    return html;
  }

  /// Same check as [isChallengePage] but on a full HTML document:
  /// the title is pulled out of the document first. A cached page
  /// can be a stale challenge page — callers use this to reject one
  /// instead of parsing it as an (empty) list.
  static bool isChallengeHtml(String html) {
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    return isChallengePage(
      title: titleMatch?.group(1) ?? '',
      bodySnippet: html,
    );
  }

  // ------------------------------------------------------------------
  // MOBILE: HeadlessInAppWebView (invisible, automatic)
  // ------------------------------------------------------------------

  /// Decides whether an onLoadStop may complete the solve. Only a real page
  /// with captured HTML counts — a loadStop on a page that is still loading
  /// (null/empty HTML) must NOT complete, or the poll loop below would be
  /// dead and the solve would return null even though the challenge had
  /// already been cleared. See the Android log regression this guards.
  @visibleForTesting
  static bool shouldCompleteFromLoadStop(String title, String? capturedHtml) =>
      capturedHtml != null &&
      capturedHtml.isNotEmpty &&
      !isChallengePage(title: title, bodySnippet: '');

  static Future<HeadlessSolveResult> _solveHeadless(
    String url,
    Duration timeout, {
    bool captureFileUrl = false,
  }) async {
    HeadlessInAppWebView? headless;
    // 下载回调由平台侧送达，这里只留**第一个**地址：那一发就是浏览器自己
    // 认领的文件，比事后猜落地页可靠。取文件那一腿之外的模式不填它。
    String? downloadUrl;
    String? landedUrl;
    // 页面已经落定（过墙了、document 读完了）但还没见到文件的时刻。下载
    // 回调要的就宽限这么一下：`/dl/` 过墙之后是先重定向再交文件的。
    DateTime? settledWithoutFileAt;
    try {
      final completer = Completer<HeadlessSolveResult>();
      final controllerHolder = Completer<InAppWebViewController>();

      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        // 安全基线与阅读器对齐（审查 2026-11-21 5.4）——见
        // webview_security.dart 的文档。
        initialSettings: kThirdPartyWebViewSettings,
        // 只在取文件地址那一腿挂这个回调：flutter_inappwebview 见到它会替
        // headless WebView 打开 `useOnDownloadStart`，Android 交出文件时
        // 地址就从这里进来。书页那条腿不挂，免得动到已经验过的产出。
        onDownloadStartRequest: captureFileUrl
            ? (controller, request) {
                final target = _secureUrl(request.url.toString());
                if (target != null && downloadUrl == null) {
                  downloadUrl = target;
                }
              }
            : null,
        onLoadStop: captureFileUrl
            ? null
            : (controller, loadedUrl) async {
          try {
            final title = (await controller.getTitle()) ?? '';
            final bodySnippet =
                (await _js(
                  controller,
                  "document.body ? document.body.innerHTML.slice(0, 3000) : ''",
                )) ??
                '';
            _logger.debug(
              'Headless load stopped',
              tag: 'ChallengeSolver',
              metadata: {'title': title, 'url': loadedUrl.toString()},
            );
            if (isChallengePage(title: title, bodySnippet: bodySnippet)) {
              return; // challenge page; wait for next load
            }
            // Not ready yet (readyState != complete)? Just wait — the poll
            // loop picks the page up. Never complete with null here: that
            // used to kill the solve right after the challenge was cleared.
            final html = await _captureHtml(controller);
            if (shouldCompleteFromLoadStop(title, html) &&
                !completer.isCompleted) {
              completer.complete(
                HeadlessSolveResult(html: html, landedUrl: lastNavigatedUrl),
              );
            }
          } catch (e) {
            _logger.debug(
              'Headless onLoadStop check failed',
              tag: 'ChallengeSolver',
              metadata: {'error': e.toString()},
            );
          }
        },
        onWebViewCreated: (controller) {
          if (!controllerHolder.isCompleted) {
            controllerHolder.complete(controller);
          }
        },
      );

      unawaited(headless.run());
      final deadline = DateTime.now().add(timeout);
      InAppWebViewController? controller;
      while (DateTime.now().isBefore(deadline)) {
        if (completer.isCompleted) break;
        // Headless webviews can stop loading without an onLoadStop for the
        // final page; also poll the controller directly.
        try {
          controller ??= await _waitForController(controllerHolder);
          // Record this WebView's UA as soon as the controller exists:
          // the UA is fixed per WebView, and whatever clearance this
          // run earns was minted against it.
          if (controller != null && _wallUserAgents[_hostOf(url)] == null) {
            await _rememberWallUserAgent(controller, url);
          }
          final direct = downloadUrl;
          if (captureFileUrl && direct != null && !completer.isCompleted) {
            completer.complete(
              HeadlessSolveResult(
                fileUrl: direct,
                fileSource: 'download-start',
                landedUrl: landedUrl,
              ),
            );
            break;
          }
          if (controller != null && captureFileUrl) {
            // 浏览器已经走到哪儿：落地地址看着就是个文件也算数——有的
            // 镜像不走下载回调，而是把 WebView 直接导航到直链上。
            landedUrl = _secureUrl((await controller.getUrl())?.toString());
            final landed = landedUrl;
            if (landed != null && looksLikeFileUrl(landed)) {
              if (!completer.isCompleted) {
                completer.complete(
                  HeadlessSolveResult(
                    fileUrl: landed,
                    fileSource: 'landed-url',
                    landedUrl: landed,
                  ),
                );
              }
              break;
            }
            // 过墙了、页面也落定了，却迟迟没有文件：再等 10 秒就给结论。
            // 没有这一步，`/dl/` 答一张普通页面（配额页、"请稍后"页）时
            // 用户要为一发注定没有文件的下载干等整个超时。
            final withoutFile = settledWithoutFileAt;
            if (landed != null &&
                !looksLikeFileUrl(landed) &&
                await _pageSettled(controller)) {
              settledWithoutFileAt = withoutFile ?? DateTime.now();
              if (withoutFile != null &&
                  DateTime.now().difference(withoutFile) >=
                      const Duration(seconds: 10) &&
                  !completer.isCompleted) {
                completer.complete(
                  HeadlessSolveResult(landedUrl: landed),
                );
                break;
              }
            }
          }
          if (controller != null && !captureFileUrl) {
            final title = (await controller.getTitle()) ?? '';
            // Same check as onLoadStop: a wall page whose title carries
            // no challenge marker must not complete the solve — check
            // the body too, not the title alone.
            final bodySnippet =
                (await _js(
                  controller,
                  "document.body ? document.body.innerHTML.slice(0, 3000) : ''",
                )) ??
                '';
            if (title.isNotEmpty &&
                !isChallengePage(title: title, bodySnippet: bodySnippet)) {
              final html = await _captureHtml(controller);
              if (html != null && html.isNotEmpty && !completer.isCompleted) {
                completer.complete(
                  HeadlessSolveResult(html: html, landedUrl: lastNavigatedUrl),
                );
              }
            }
          }
        } catch (error) {
          logIgnored('webview_challenge_solver', error);
        }
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // The only place the completer may complete empty: the deadline.
      if (!completer.isCompleted) {
        completer.complete(
          HeadlessSolveResult(landedUrl: landedUrl ?? lastNavigatedUrl),
        );
      }
      return await completer.future;
    } catch (e, st) {
      _logger.error(
        'Headless challenge solver failed',
        tag: 'ChallengeSolver',
        error: e,
        stackTrace: st,
      );
      return const HeadlessSolveResult();
    } finally {
      try {
        await headless?.dispose();
      } catch (error) {
        logIgnored('webview_challenge_solver', error);
      }
    }
  }

  static Future<InAppWebViewController?> _waitForController(
    Completer<InAppWebViewController> completer,
  ) async {
    if (completer.isCompleted) return await completer.future;
    // Poll the completer without a typed onTimeout closure.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (completer.isCompleted) return await completer.future;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  // ------------------------------------------------------------------
  // SHARED HELPERS
  // ------------------------------------------------------------------

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? '';

  /// 只放行 https 的绝对地址，其余一律 null。
  ///
  /// 这条链的产出会被当成"下载器的下一个地址"用（见
  /// `ZLibraryDownloads.downloadBook`），所以校验放在生产端：一个 http
  /// 直链、或 `getUrl()` 还没导航完时的空串，都不该往下传。
  static String? _secureUrl(String? url) {
    final raw = url?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return raw;
  }

  /// 一个地址"看着就是本书"：扩展名是电子书格式，或查询里带着文件名/
  /// 附件Disposition。非 https 直接否。
  ///
  /// 这是 `/dl/{token}` 那一跳的第二把判据（第一把是 WebView 自己的下载
  /// 回调）：Z-Library 的直链常见形态是 `…/file/xxxx.epub?filename=…`，
  /// 扩展名和 query 各有一半样本只有其中一个，所以两条都认。
  @visibleForTesting
  static bool looksLikeFileUrl(String url) {
    if (_secureUrl(url) == null) return false;
    final uri = Uri.parse(url);
    final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    const exts = [
      'epub',
      'pdf',
      'mobi',
      'azw',
      'azw3',
      'azw4',
      'djvu',
      'fb2',
      'lit',
      'cbr',
      'cbz',
      'zip',
      'txt',
      'rtf',
      'odt',
      'chm',
    ];
    final dot = last.lastIndexOf('.');
    if (dot > 0 && dot < last.length - 1) {
      if (exts.contains(last.substring(dot + 1).toLowerCase())) return true;
    }
    final query = uri.query.toLowerCase();
    return query.contains('filename=') || query.contains('content-disposition');
  }

  /// 这一发 WebView 有没有"落定"：document 读完了，而且页面不是校验页。
  /// 取文件地址那一腿用它来给下载回调划一条等待尽头（见 `_solveHeadless`）
  /// ——校验页落定不代表没墙，所以两道判据都要过。
  static Future<bool> _pageSettled(InAppWebViewController controller) async {
    final ready = await _js(controller, "document.readyState");
    if (ready != 'complete') return false;
    final title = (await controller.getTitle()) ?? '';
    final bodySnippet =
        (await _js(
          controller,
          "document.body ? document.body.innerHTML.slice(0, 3000) : ''",
        )) ??
        '';
    return !isChallengePage(title: title, bodySnippet: bodySnippet);
  }

  /// Captures outerHTML once the document is complete and settled.
  static Future<String?> _captureHtml(InAppWebViewController controller) async {
    final ready = await _js(controller, "document.readyState") ?? '';
    if (ready != 'complete') return null;
    // Adaptive settle instead of a fixed 2 s sleep: late XHR content must
    // land in the DOM, but a page that is already stable should not pay
    // the full delay. Poll the document length every 500 ms and stop
    // once two consecutive reads agree (never earlier than 1 s, never
    // later than 3 s — the old fixed delay was 2 s).
    var previous = -1;
    for (var i = 0; i < 6; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final len =
          int.tryParse(
            await _js(
                  controller,
                  "document.documentElement.outerHTML.length",
                ) ??
                '',
          ) ??
          -1;
      if (i >= 1 && len > 0 && len == previous) break;
      previous = len;
    }
    final html = await _js(controller, "document.documentElement.outerHTML");
    // The poll loop used to check only the title before capturing: a
    // wall page whose title carries no challenge marker would be
    // captured here as solved. Reject a captured challenge page
    // outright so the solve keeps waiting for the real page instead.
    if (html != null && isChallengeHtml(html)) return null;
    if (html != null) {
      // 下载失败那句要能说出「请求的是书页、落在的却是首页」。值本身
      // 不进文案（插件按 host+path 结构掩码），这里只留最后一次的地址。
      try {
        lastNavigatedUrl = (await controller.getUrl())?.toString() ?? '';
      } catch (e) {
        logIgnored('webview_challenge_solver', e);
      }
    }
    return html;
  }

  /// Evaluates JS and decodes the result, handling JSON-encoded bridges.
  /// Uses the flutter_inappwebview 6.x API (`evaluateJavascript`, named
  /// `source:`) — upstream's v5-spelled `evaluateJavaScript` does not
  /// exist in v6.
  static Future<String?> _js(
    InAppWebViewController controller,
    String script,
  ) async {
    try {
      final result = await controller.evaluateJavascript(source: script);
      if (result == null) return null;
      final s = result.toString();
      if (s == 'null') return null;
      // WebKit and inappwebview bridges may return strings JSON-encoded.
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
        try {
          final decoded = json.decode(s);
          if (decoded is String) return decoded;
        } catch (error) {
          logIgnored('webview_challenge_solver', error);
        }
        return s.substring(1, s.length - 1);
      }
      return s;
    } catch (error) {
      logIgnored('webview_challenge_solver', error);
      return null;
    }
  }
}
