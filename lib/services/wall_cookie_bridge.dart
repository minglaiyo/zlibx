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
/// Only the page's own host is read. The known wall-clearance cookies in
/// [wallCookieNames] are copied first; when the wall minted its
/// clearance under a name that list does not know, every *other* cookie
/// of that one host is copied instead. The session `remix_*` pair is
/// never copied either way, and the plugin strips the whole `Cookie`
/// header for cross-host download links, so neither case can reach a
/// third party. Returns what the jar held and what went into Dio, so
/// the caller can say which of the two cases happened.
class WallBridgeResult {
  const WallBridgeResult({
    required this.bridged,
    required this.jarCookieNames,
    required this.usedFallback,
  });

  final List<String> bridged;
  final List<String> jarCookieNames;

  /// 白名单一枚都没命中、于是改用"本站非会话 cookie 全带"那条兜底。
  final bool usedFallback;
}

/// 该搬进 Dio 的 cookie 名字。白名单优先；一枚没命中就退到"这台主机上
/// 的非会话 cookie 全带"。`remix_*` 在两种情况下都不选。
///
/// 只认名字、不碰值，所以这条兜底能被单测钉住——它决定的是"解过墙的
/// WebView 到底有没有把下载救回来"，而真机上唯一能看见的只有最后那句
/// 下载失败文案。
({List<String> bridged, bool usedFallback}) selectBridgedCookieNames(
  Iterable<String> jarNames,
) {
  final known = jarNames.where(wallCookieNames.contains).toList();
  if (known.isNotEmpty) return (bridged: known, usedFallback: false);
  final others = jarNames.where((n) => !n.startsWith('remix_')).toList();
  return (bridged: others, usedFallback: others.isNotEmpty);
}

Future<WallBridgeResult> bridgeWallCookies(
  ZLibraryApi api,
  String pageUrl,
) async {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null || uri.host.isEmpty) {
    return const WallBridgeResult(
      bridged: [],
      jarCookieNames: [],
      usedFallback: false,
    );
  }
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri('${uri.scheme}://${uri.host}/'),
  );
  final jarNames = cookies.map((c) => c.name).toList();
  final byName = <String, String>{};
  for (final cookie in cookies) {
    // Cookie.value is dynamic in flutter_inappwebview 6.1.5 — cast once
    // (strict-casts flags the bare bool test / map assignment).
    final value = cookie.value as String?;
    if (value == null || value.isEmpty) continue;
    byName[cookie.name] = value;
  }
  // 白名单没命中时，把这一台主机上的非会话 cookie 全带上。这不是放宽
  // 隐私面：`remix_*` 仍然一枚不带，而且地址永远是镜像自己（插件在跨
  // 主机那一跳会把整个 `Cookie` 头摘掉）。它换掉的是"墙那枚叫什么"这个
  // 在设备外永远查不到的知识——2026-11-24 那份 `Bad state: Invalid hash`
  // 里，解墙成功的 WebView 和 0 枚回灌的 Dio 之间差的就是这个。
  final selection = selectBridgedCookieNames(byName.keys);
  final wall = <String, String>{
    for (final name in selection.bridged) name: byName[name]!,
  };
  if (wall.isNotEmpty) api.setWallCookies(wall);
  // The UA belongs with the cookies (same solve, same host): without
  // it the replayed clearance can be rejected on UA mismatch. The
  // plugin keeps it only for requests to its own host.
  final wallUserAgent = WebviewChallengeSolver.wallUserAgentFor(pageUrl);
  if (wallUserAgent != null) {
    api.setWallUserAgent(wallUserAgent);
  }
  return WallBridgeResult(
    bridged: wall.keys.toList(),
    jarCookieNames: jarNames,
    usedFallback: selection.usedFallback,
  );
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

/// 下载这条腿的过墙：给插件的 `wallCookieRefresh` 钩子用（2026-11-24）。
///
/// 与其它求解的区别是**不看拿回来的 HTML**。`/dl/{token}` 过了墙之后交出来
/// 的是文件而不是页面，求解器按设计抓不到正文。这一发产出两样东西：
///  1. WebView 的 cookie jar 里多了一枚墙 cookie —— [bridgeWallCookies]
///     把它搬进 Dio（老路，成败取决于墙那枚 cookie 的**名字**在不在白名单
///     里，而这个名字在设备外看不见）；
///  2. 浏览器在这一跳被交予的**文件地址** —— `api.recordDlFileCapture`
///     交回插件（第 9 轮）。真机第 7 份报告钉的就是第 1 条不够：解完墙重发
///     `/dl/` 仍是 `HTTP 503 + text/html`，而浏览器同一个地址上能一路走到
///     文件。所以两条一起记，下载那边优先用第 2 条。
///
/// 所以求解「失败」（超时、抓不到 HTML）也照样回灌、照样重试：判它成败的是
/// 那一发重发的答复，不是求解本身。
///
/// headless：下载跑在后台任务池里，把一张校验页弹到用户脸上等于劫持
/// 界面；过不了墙就让原错误照旧抛出去（`DownloadHtmlException`，
/// `isWall` 为真，文案里带掩码后的地址）。
///
/// 返回 false = 这台设备根本没法解（WebView 不可用 / 会话装不上），
/// 调用方就不该为它重发一遍。
Future<bool> solveWallForDownloadLink(
  ZLibraryApi api,
  String url, {
  String? userId,
  String? userKey,
}) async {
  if (!WebviewChallengeSolver.isSupported) return false;
  // 本站地址才解。下面 installSessionCookies 按 URL 的 host 往 WebView
  // 的 jar 里写会话——照着一条第三方 CDN 地址求解，等于把 remix_userid /
  // remix_userkey 装进别人的域，而且那根本不是 mirror 的那堵墙。
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty || host != api.domain) return false;
  final hasSession = userId != null && userKey != null && userKey.isNotEmpty;
  if (hasSession) {
    await installSessionCookies(
      userId: userId,
      userKey: userKey,
      pageUrl: url,
    );
  }
  try {
    final solve = await WebviewChallengeSolver.solveHeadlessForFileUrl(url);
    await bridgeWallCookies(api, url);
    // 抓到的地址只交给插件的下载器用，且只有 https 才收（见
    // `ZLibraryApi.recordDlFileCapture`）。没抓到就什么都不记：那一条路上
    // 插件自己会说「过墙了但这一跳仍未给出文件」，不需要这里再递现场。
    api.recordDlFileCapture(url, fileUrl: solve.fileUrl);
    return true;
  } finally {
    // O8: the session only lives for this solve (see BooklistSolver).
    if (hasSession) await deleteSessionCookies(pageUrl: url);
  }
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
