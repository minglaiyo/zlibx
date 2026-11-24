import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';
import 'package:zlibx/services/wall_cookie_bridge.dart';

// 下载这条腿的过墙（2026-11-24）：`/dl/{token}` 在真机上站在浏览器校验
// 后面，插件开不了 WebView，所以由 App 求解一次、把墙 cookie 回灌进
// Dio、插件再发同一发请求。这里能验的是不管求解成不成功都必须守住的
// 两条边界——会话绝不进别人的 jar，钩子绝不被拉去弹验证页。

void main() {
  late ZLibraryApi api;

  setUp(() {
    api = ZLibraryApi(dio: Dio());
    // 让「这台设备能解」成立，这样返回 false 只可能是别的原因。
    WebviewChallengeSolver.overrideIsSupported = true;
  });

  tearDown(() {
    WebviewChallengeSolver.overrideIsSupported = null;
  });

  test('a link on another host is never solved', () async {
    // installSessionCookies 按 URL 的 host 往 WebView 的 cookie jar 里
    // 写 remix_userid / remix_userkey。照着一条 CDN 地址求解等于把登录
    // 会话装进第三方域——而且那根本不是 mirror 的那堵墙。
    final solved = await solveWallForDownloadLink(
      api,
      'https://cdn.example.com/dl/ABVGVr08wz',
      userId: '9999999',
      userKey: 'secret-key',
    );
    expect(solved, isFalse);
  });

  test('a malformed or scheme-less url is refused the same way', () async {
    for (final bad in ['', '/dl/ABVGVr08wz', 'not a url']) {
      expect(
        await solveWallForDownloadLink(api, bad),
        isFalse,
        reason: "'$bad' names no host to solve",
      );
    }
  });

  test('an unsupported device reports no solve instead of hanging', () async {
    WebviewChallengeSolver.overrideIsSupported = false;
    expect(
      await solveWallForDownloadLink(
        api,
        'https://${api.domain}/dl/ABVGVr08wz',
      ),
      isFalse,
    );
  });

  test('the plugin hook is what carries this capability', () async {
    // 接线形状本身是判据：App 只把它交给插件，插件撞墙时才调用它。
    // 没接线（纯 Dio 环境）时钩子必须保持 null——否则 CI 里的下载会
    // 以为自己能开 WebView。
    expect(api.wallCookieRefresh, isNull);
    var called = 0;
    api.wallCookieRefresh = (url) async {
      called++;
      return true;
    };
    expect(await api.wallCookieRefresh!('https://${api.domain}/dl/x'), isTrue);
    expect(called, 1);
  });
}
