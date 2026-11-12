import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// After the WebView challenge solver passes a browser check, copy
/// the wall-clearance cookies it earned (`__diamwall`, `cf_clearance`,
/// ...) from the WebView's CookieManager into the API layer's Dio
/// headers, so the next HTML load passes the wall through fast Dio
/// instead of solving again (up to 60 s per solve).
///
/// Only the page's own host is read, and only non-session cookies are
/// copied — the plugin already sends the login session from its own
/// state. The cookies go to the same mirror Dio already talks to;
/// nothing is sent to any other host (the plugin strips the whole
/// `Cookie` header for cross-host download links). Callers invoke
/// this right after a successful solve, before parsing the HTML.
Future<void> bridgeWallCookies(ZLibraryApi api, String pageUrl) async {
  final uri = Uri.tryParse(pageUrl);
  if (uri == null || uri.host.isEmpty) return;
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri('${uri.scheme}://${uri.host}/'),
  );
  final wall = <String, String>{};
  for (final cookie in cookies) {
    if (cookie.name == 'remix_userid' ||
        cookie.name == 'remix_userkey' ||
        cookie.value.isEmpty) {
      continue;
    }
    wall[cookie.name] = cookie.value;
  }
  if (wall.isNotEmpty) api.setWallCookies(wall);
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
