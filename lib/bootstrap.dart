// Startup bootstrap (P3-4 split of main.dart): everything main() did
// before runApp, extracted so main() is only the sequencing. Pure
// extraction — execution order and behaviour are unchanged; the long
// inline comments moved here as doc comments on each function.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/rust_annas.dart';
import 'core/rust_article.dart';
import 'core/rust_book_detail.dart';
import 'core/rust_booklists.dart';
import 'core/rust_books.dart';
import 'core/rust_fulltext.dart';
import 'core/rust_libgen.dart';
import 'screens/challenge_solver/challenge_solver_screen.dart';
import 'services/app_lock_service.dart';
import 'services/challenge_html_cache.dart';
import 'services/domain_probe.dart';
import 'services/download_foreground_service.dart';
import 'services/hive_service.dart';
import 'services/instance_manager.dart';
import 'services/mirror_trust.dart';
import 'services/storage_service.dart';
import 'services/wall_cookie_bridge.dart';
import 'services/web_keepalive.dart';
import 'services/web_service.dart';
import 'services/webview_challenge_solver.dart';
import 'utils/app_log.dart';
import 'utils/diagnostics.dart';

/// Global error hooks (M2): uncaught async errors (e.g. inside an
/// unawaited(...) Future) and framework errors otherwise vanish
/// silently in a release + obfuscated build — the user only sees
/// "it doesn't work". [logIgnored] records only the tag + exception
/// TYPE + timestamp (never the message or URL), so nothing sensitive
/// reaches the ring log; Settings can dump it for bug reports.
///
/// Debug: show the full error + stack on the console FIRST — the ring
/// log only keeps the exception type, which is not enough to debug.
/// Release: the ring log additionally records the topmost
/// `package:zlibx` frame (file:line) and, for network errors, the HTTP
/// status code — both data-free, see [Diagnostics.record].
void installGlobalErrorHooks() {
  FlutterError.onError = (details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
      AppLog.error(
        'Flutter error',
        tag: 'flutter',
        error: details.exception,
        stackTrace: details.stack,
      );
    }
    logIgnored('flutter', details.exception, stack: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      AppLog.error(
        'Uncaught async error',
        tag: 'platform',
        error: error,
        stackTrace: stack,
      );
    }
    logIgnored('platform', error, stack: stack);
    return true;
  };
}

/// Registers the Rust parser bridges (Phases 2–4 + JSON sink). Pure
/// in-memory hook registration — the FRB engine initializes lazily on
/// the first use (see rust_fulltext.dart), so startup timing is
/// unaffected and a missing .so falls back to Dart silently.
void registerRustParsers() {
  // Phase 2: route the fulltext page parse through the Rust bridge.
  injectRustFulltextParser();
  // Phase 3: same for the article search page parse (文章 tab).
  injectRustArticleParser();
  // Phase 3: same for the book detail metadata rows.
  injectRustBookDetailParser();
  // Phase 3: same for booklists / category / download history.
  injectRustBooklistParsers();
  // Phase 4: Anna's Archive heavy parsers (search + md5 detail).
  injectRustAnnasParsers();
  // Phase 4: Library Genesis / Open Library external feeds.
  injectRustExternalParsers();
  // JSON sink: route the eapi book-list decode (_booksOf) through Rust.
  injectRustBooksParser();
}

/// Registers the background-download foreground-service bridge and
/// requests the notification permission (Android 13+) up front (O1).
void registerBackgroundDownload() {
  DownloadForegroundService.register();
  unawaited(DownloadForegroundService.requestNotificationPermission());
}

/// Registers the web keep-alive bridge and wires the notification's
/// Stop button. The handler lives here, not in the web service screen:
/// the button is pressed when the user is NOT looking at the screen
/// (it is on the lock screen), so the callback must not depend on any
/// widget being mounted. The native service stops itself first; this
/// stops the HttpServer, which notifies the screen through its
/// listener.
void registerWebKeepalive() {
  WebKeepalive.register();
  WebKeepalive.onAction = (action) {
    if (action != 'stop') return;
    unawaited(
      WebService.shared.stop().whenComplete(() => WebKeepalive.stop()),
    );
  };
}

/// Restores the privacy lock from disk before runApp.
///
/// The lock decision used to live only in didChangeAppLifecycleState,
/// but the in-memory "left foreground at" timestamp is gone after a
/// cold start — and Android killing a backgrounded app is normal, so a
/// user could swipe-kill and reopen to bypass the lock. This reads the
/// last foreground-leave time recorded on disk and re-judges with the
/// same thresholds. Reads settingsBox directly: providers do not exist
/// yet, and this decision takes no UI subscription.
void restoreAppLockOnStartup() {
  final appLockEnabled = HiveService.settingsBox.get('appLockEnabled');
  final appLockTimeout = HiveService.settingsBox.get('appLockTimeoutSeconds');
  final leftForegroundAt = HiveService.settingsBox.get(
    appLockLeftForegroundKey,
  );
  AppLockController.instance.restoreOnStartup(
    enabled: appLockEnabled is bool && appLockEnabled,
    timeoutSeconds: appLockTimeout is int ? appLockTimeout : 0,
    leftForegroundAtMs: leftForegroundAt is int ? leftForegroundAt : null,
  );
}

/// Runs the one-time startup migrations. Awaits the mirror-trust
/// grandfathering (existing installs keep their current line without
/// a trust prompt); the cookie cleanup and favorites migration are
/// fire-and-forget and never throw.
///
/// The cookie cleanup runs after the migration above so the trusted
/// set is complete: a SIGKILL skips every `finally`, so a solver
/// session can survive in the WebView's cookie store and ride the next
/// anonymous solve for the same host (L7). Startup must not block on
/// the cookie store.
///
/// The favorites migration moves the legacy shared 'favorite_books'
/// list to the account signed in right now (see
/// [StorageService.migrateLegacyFavorites]). If nobody is signed in
/// yet it defers to the first favorites access after login, and the
/// per-operation guard in the storage layer covers that path too.
Future<void> runStartupMigrations() async {
  // Existing installs keep their current line without a trust prompt.
  await MirrorTrust.grandfatherCurrent();
  unawaited(deleteStaleSessionCookies());
  unawaited(StorageService().migrateLegacyFavorites());
}

/// Warms the caches the first search / download would otherwise wait
/// on. Both calls are fire-and-forget and never throw.
///
/// [InstanceManager.refreshOnStartup] warms the Anna's Archive /
/// LibGen mirror catalogue (open-slum.org); it restores the cached
/// list first. [DomainProbe.reverifyDiscoveredHosts] cold-start
/// re-verifies discovered redirect targets (plan item 4): a host a
/// past probe adopted is only trusted again after it still answers
/// `/eapi/info/domains` with a family domain in the list — a host
/// that fails is dropped from `discovered_hosts`, not retried.
void warmCaches() {
  // R2: 这两项都不影响首屏，却在启动期与首屏请求抢连接和带宽——
  // 延迟 10 秒等首屏数据落地后再跑。线路检测失败的 O3 分支（立即
  // 强制测速换线）不受影响，走的是 splash 自己的触发。
  Future.delayed(const Duration(seconds: 10), () {
    unawaited(InstanceManager().refreshOnStartup());
    unawaited(DomainProbe.reverifyDiscoveredHosts());
  });
}

/// Registers the visible challenge-solver fallback: when the headless
/// challenge solve fails (e.g. a human CAPTCHA shows), the solver is
/// shown as a visible page over the current screen. The user watches
/// the check clear and the page closes itself as soon as the HTML is
/// captured; the caller then parses the cached HTML instead of
/// retrying a doomed Dio request.
///
/// Registered before runApp so it is in place before any Anna search
/// can run; the callback only uses [rootNavigatorKey] when it is
/// actually invoked.
void registerChallengeSolverFallback(
  GlobalKey<NavigatorState> rootNavigatorKey,
) {
  WebviewChallengeSolver.visibleSolverFallback = (url) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return null;
    final solved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ChallengeSolverScreen(url: url)),
    );
    return solved == true ? ChallengeHtmlCache.get(url) : null;
  };
}
