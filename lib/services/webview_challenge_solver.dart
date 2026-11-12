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
import 'package:zlibx/services/external_logger.dart';

class WebviewChallengeSolver {
  WebviewChallengeSolver._();

  static final AppLogger _logger = AppLogger();

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
      _logger.debug('Joining in-flight challenge solve',
          tag: 'ChallengeSolver', metadata: {'url': url});
      return existing;
    }
    final future = _fetchHtmlAfterChallengeUncancelable(url, timeout);
    _inFlightSolves[url] = future;
    // Remove on completion — whenComplete returns a NEW future, so the
    // map entry must point at `future`, and unawaited cleanup keeps the
    // map bounded.
    unawaited(
      future.whenComplete(() => _inFlightSolves.remove(url)),
    );
    return future;
  }

  static Future<String?> _fetchHtmlAfterChallengeUncancelable(
    String url,
    Duration? timeout,
  ) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 60);

    final tryHeadless = guiEnabled && headlessEnabled;
    var html = tryHeadless ? await _solveHeadless(url, effectiveTimeout) : null;

    if (html == null && _isMobile && visibleSolverFallback != null) {
      _logger.info('Headless solve failed, using visible fallback',
          tag: 'ChallengeSolver', metadata: {'url': url});
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
    final html = await _solveHeadless(
      url,
      timeout ?? const Duration(seconds: 60),
    );
    if (html != null) {
      ChallengeHtmlCache.store(url, html);
    }
    return html;
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

  static Future<String?> _solveHeadless(String url, Duration timeout) async {
    HeadlessInAppWebView? headless;
    try {
      final completer = Completer<String?>();
      final controllerHolder = Completer<InAppWebViewController>();

      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: false,
        ),
        onLoadStop: (controller, loadedUrl) async {
          try {
            final title = (await controller.getTitle()) ?? '';
            final bodySnippet = (await _js(controller,
                    "document.body ? document.body.innerHTML.slice(0, 3000) : ''")) ??
                '';
            _logger.debug('Headless load stopped',
                tag: 'ChallengeSolver',
                metadata: {'title': title, 'url': loadedUrl.toString()});
            if (isChallengePage(title: title, bodySnippet: bodySnippet)) {
              return; // challenge page; wait for next load
            }
            // Not ready yet (readyState != complete)? Just wait — the poll
            // loop picks the page up. Never complete with null here: that
            // used to kill the solve right after the challenge was cleared.
            final html = await _captureHtml(controller);
            if (shouldCompleteFromLoadStop(title, html) &&
                !completer.isCompleted) {
              completer.complete(html);
            }
          } catch (e) {
            _logger.debug('Headless onLoadStop check failed',
                tag: 'ChallengeSolver', metadata: {'error': e.toString()});
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
          if (controller != null) {
            final title = (await controller.getTitle()) ?? '';
            // Same check as onLoadStop: a wall page whose title carries
            // no challenge marker must not complete the solve — check
            // the body too, not the title alone.
            final bodySnippet = (await _js(controller,
                    "document.body ? document.body.innerHTML.slice(0, 3000) : ''")) ??
                '';
            if (title.isNotEmpty &&
                !isChallengePage(title: title, bodySnippet: bodySnippet)) {
              final html = await _captureHtml(controller);
              if (html != null && html.isNotEmpty && !completer.isCompleted) {
                completer.complete(html);
              }
            }
          }
        } catch (error) { logIgnored('webview_challenge_solver', error); }
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // The only place the completer may complete with null: the deadline.
      if (!completer.isCompleted) completer.complete(null);
      return await completer.future;
    } catch (e, st) {
      _logger.error('Headless challenge solver failed',
          tag: 'ChallengeSolver', error: e, stackTrace: st);
      return null;
    } finally {
      try {
        await headless?.dispose();
      } catch (error) { logIgnored('webview_challenge_solver', error); }
    }
  }

  static Future<InAppWebViewController?> _waitForController(
      Completer<InAppWebViewController> completer) async {
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
      final len = int.tryParse(
            await _js(controller, "document.documentElement.outerHTML.length") ??
                '',
          ) ??
          -1;
      if (i >= 1 && len > 0 && len == previous) break;
      previous = len;
    }
    final html =
        await _js(controller, "document.documentElement.outerHTML");
    // The poll loop used to check only the title before capturing: a
    // wall page whose title carries no challenge marker would be
    // captured here as solved. Reject a captured challenge page
    // outright so the solve keeps waiting for the real page instead.
    if (html != null && isChallengeHtml(html)) return null;
    return html;
  }

  /// Evaluates JS and decodes the result, handling JSON-encoded bridges.
  /// Uses the flutter_inappwebview 6.x API (`evaluateJavascript`, named
  /// `source:`) — upstream's v5-spelled `evaluateJavaScript` does not
  /// exist in v6.
  static Future<String?> _js(InAppWebViewController controller, String script) async {
    try {
      final result = await controller.evaluateJavascript(source: script);
      if (result == null) return null;
      var s = result.toString();
      if (s == 'null') return null;
      // WebKit and inappwebview bridges may return strings JSON-encoded.
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
        try {
          final decoded = json.decode(s);
          if (decoded is String) return decoded;
        } catch (error) { logIgnored('webview_challenge_solver', error); }
        return s.substring(1, s.length - 1);
      }
      return s;
    } catch (error) {
      logIgnored('webview_challenge_solver', error);
      return null;
    }
  }
}
