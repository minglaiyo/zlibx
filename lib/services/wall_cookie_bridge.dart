import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/diagnostics.dart';
import 'webview_challenge_solver.dart';

/// Wall-clearance cookies the solver earns and that Dio needs to pass the
/// same wall on the next request. Only these are copied into Dio (O8):
/// previously every non-session cookie on the host was copied, which could
/// carry tracking / non-wall cookies into the request headers. A cookie
/// missing from this list only means Dio re-solves the wall on the next
/// request — extend the list if a mirror uses a different clearance
/// cookie, but never add the session `remix_*` pair here.
const List<String> wallCookieNames = [
  '__diamwall',
  'cf_clearance',
  '__cf_bm',
  'ddos_guard',
  '_dd_',
  '__ddg1_',
  '__ddg2_',
];

/// After the WebView challenge solver passes a browser check, copy
/// the wall-clearance cookies it earned (`__diamwall`, `cf_clearance`,
/// ...) from the WebView's CookieManager into the API layer's Dio
/// headers, so the next HTML load passes the wall through fast Dio
/// instead of solving again (up to 60 s per solve).
///
/// The WebView User-Agent that cleared the wall is replayed too when
/// the solver captured one (W1): `cf_clearance` is commonly bound to
/// the UA it was minted with, so a Dio with a different UA can loop
/// 403 despite carrying valid cookies.
///
/// Only the page's own host is read, and only the known wall-clearance
/// cookies in [wallCookieNames] are copied (O8) — the session
/// `remix_*` pair is never copied (the plugin sends the login session
/// from its own state), and neither are tracking / non-wall cookies.
/// The cookies go to the same mirror Dio already talks to; nothing is
/// sent to any other host (the plugin strips the whole `Cookie` header
/// for cross-host download links). Callers invoke this right after a
/// successful solve, before parsing the HTML.
Future<void> bridgeWallCookies(ZLibraryApi api, String pageUrl) async {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null || uri.host.isEmpty) return;
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri('${uri.scheme}://${uri.host}/'),
  );
  final wall = <String, String>{};
  for (final cookie in cookies) {
    // Cookie.value is dynamic in flutter_inappwebview 6.1.5 — cast once
    // (strict-casts flags the bare bool test / map assignment).
    final value = cookie.value as String?;
    // O8: copy only known wall-clearance cookies, not every non-session
    // cookie on the host. The session pair is excluded by the allow-list
    // too (it is never in [wallCookieNames]).
    if (!wallCookieNames.contains(cookie.name) ||
        value == null ||
        value.isEmpty) {
      continue;
    }
    wall[cookie.name] = value;
  }
  if (wall.isNotEmpty) api.setWallCookies(wall);
  // The UA belongs with the cookies (same solve, same host): without
  // it the replayed clearance can be rejected on UA mismatch. The
  // plugin keeps it only for requests to its own host.
  final wallUserAgent = WebviewChallengeSolver.wallUserAgentFor(pageUrl);
  if (wallUserAgent != null) {
    api.setWallUserAgent(wallUserAgent);
  }
}

/// Install the `remix_userid` / `remix_userkey` session into the
/// WebView's CookieManager for the page's host (the reader's pattern —
/// the manager is global on Android, so a headless solver WebView
/// sees them). Needed before solving a page that requires sign-in
/// (e.g. the own-booklists page). Never put the keys in a URL.
Future<void> installSessionCookies({
  required String userId,
  required String userKey,
  required String pageUrl,
}) async {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null || uri.host.isEmpty) return;
  final manager = CookieManager.instance();
  final url = WebUri('https://${uri.host}/');
  await manager.setCookie(
    url: url,
    name: 'remix_userid',
    value: userId,
    isSecure: true,
    isHttpOnly: true,
  );
  await manager.setCookie(
    url: url,
    name: 'remix_userkey',
    value: userKey,
    isSecure: true,
    isHttpOnly: true,
  );
}

/// Delete the `remix_userid` / `remix_userkey` session from the
/// WebView's CookieManager for [pageUrl]'s host — the counterpart to
/// [installSessionCookies] (O8). Solver flows call it in a `finally`
/// so the session only lives for the solve itself; account/line
/// switches and the reader call it when the session must not outlive
/// its use.
///
/// Best-effort and never throws: a CookieManager failure (WebView
/// never initialized, test host) must not mask a solve result or a
/// switch — the cookies are then dropped by the next logout, which
/// clears the whole store.
Future<void> deleteSessionCookies({required String pageUrl}) async {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null || uri.host.isEmpty) return;
  final url = WebUri('https://${uri.host}/');
  try {
    final manager = CookieManager.instance();
    await manager.deleteCookie(url: url, name: 'remix_userid');
    await manager.deleteCookie(url: url, name: 'remix_userkey');
  } catch (error) {
    logIgnored('wall_cookie_bridge', error);
  }
}
