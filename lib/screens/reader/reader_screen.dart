import 'package:zlibx/utils/diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zlibx/utils/host_utils.dart';

import '../../l10n/generated/app_localizations.dart';

import '../../services/wall_cookie_bridge.dart';
import '../../utils/app_log.dart';
import '../../utils/app_snack.dart';
class ReaderScreen extends StatefulWidget {
  final String url;
  final String title;

  /// Z-Library session, installed as WebView cookies before load.
  /// Passed through from ReaderArgs (main.dart route builder).
  final String? remixUserId;
  final String? remixUserKey;

  /// Fired when the WebView's own cookie store holds a session pair
  /// that differs from the one the app installed — i.e. the user signed
  /// in (or the site rotated the key) inside this WebView. The app
  /// adopts the fresh pair; without this the next 预览 re-installs the
  /// stale pair and the site bounces the user back to its login wall.
  final void Function(String userId, String userKey)? onSessionChanged;

  const ReaderScreen({
    super.key,
    required this.url,
    required this.title,
    this.remixUserId,
    this.remixUserKey,
    this.onSessionChanged,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  static const bool _probeEnabled = bool.fromEnvironment('LITERA_PROBE');
  InAppWebViewController? _webViewController;
  double _progress = 0;
  bool _isLoading = true;

  // 按需开启的 Litera 资源耗时记录，地址只保留脱敏后的路由。
  final List<Map<String, dynamic>> _probeLog = [];
  final DateTime _probeStart = DateTime.now();

  // 本次进入阅读器时写入 WebView 的会话对（与 widget 上的入参一致，
  // 但以实际写入为准），用于判断 WebView 里的会话是否被站内操作改掉。
  String? _installedUserId;
  String? _installedUserKey;

  // 最近一次已上报 onSessionChanged 的会话对，避免同一对重复触发。
  String? _syncedUserId;
  String? _syncedUserKey;

  // True while the route is popping: the WebView is hidden so the pop
  // transition animates pure Flutter instead of re-compositing the
  // hybrid-composition native view every frame.
  bool _webViewHidden = false;
  Animation<double>? _routeAnimation;
  VoidCallback? _routeAnimationListener;

  /// 初始阅读页 host：站内导航只允许它及其子域，其余一律外部打开。
  String get _initialHost => Uri.tryParse(widget.url)?.host ?? '';

  bool _isAllowedHost(String rawHost) {
    final host = rawHost.toLowerCase();
    final initial = _initialHost.toLowerCase();
    if (initial.isEmpty) return false;
    if (host == initial || host.endsWith('.$initial')) return true;
    // The reader lives on reader.<domain>, but the bare <domain> is the
    // same site (login, account pages) and already receives the session
    // cookies — keep it in the WebView instead of kicking it out to the
    // system browser.
    if (initial.startsWith('reader.')) {
      final bare = initial.substring('reader.'.length);
      if (host == bare || host.endsWith('.$bare')) return true;
    }
    // The site's own links may point at the canonical domain or another
    // mirror instead of the current line's domain (e.g. the reader runs
    // on reader.bookroom.lifestyle while the Log In button points at
    // z-library.mn). Those are still the same site, so they stay in the
    // WebView; only truly external hosts go to the system browser.
    return isZlibFamilyHost(host);
  }

  /// 会话改走 WebView Cookie（HttpOnly + Secure），不再拼进 URL。
  /// 阅读页在 reader.`<domain>`，其 API 也可能走 `<domain>`，两个 host 都写。
  Future<void> _installSessionCookies() async {
    final userId = widget.remixUserId;
    final userKey = widget.remixUserKey;
    if (userId == null || userKey == null) return;
    final uri = Uri.tryParse(widget.url);
    // Secure cookies are meaningless (and a leak risk) off https.
    if (uri == null || uri.host.isEmpty || uri.scheme != 'https') return;
    await _installSessionCookiesOnce();
    _installedUserId = userId;
    _installedUserKey = userKey;
    await _verifyInstalledCookies(uri.host);
  }

  /// Android 的 CookieManager 偶发吞掉 WebView 创建初期的一次写入
  /// （这正是以前那条"会话写入失败"诊断 toast 抓到的现象）。这里
  /// 静默读回校验，缺失就重试一次；再失败只记诊断日志——页面上
  /// 站点自己的登录墙就是兜底信号，不再向用户弹"请重新登录"。
  Future<void> _verifyInstalledCookies(String host) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _hasSessionCookies(host)) return;
      if (attempt < 2) await _installSessionCookiesOnce();
    }
    logIgnored(
      'reader_screen',
      StateError('session cookies missing after retry'),
    );
  }

  Future<bool> _hasSessionCookies(String host) async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://$host/'),
      );
      final names = cookies.map((c) => c.name).toSet();
      return names.contains('remix_userid') && names.contains('remix_userkey');
    } catch (error) {
      logIgnored('reader_screen', error);
      return false;
    }
  }

  /// 只写一次 Cookie（`_installSessionCookies` 的无副作用版本，供
  /// 校验重试用：不重复更新 _installed* 标记）。
  Future<void> _installSessionCookiesOnce() async {
    final userId = widget.remixUserId;
    final userKey = widget.remixUserKey;
    if (userId == null || userKey == null) return;
    final uri = Uri.tryParse(widget.url);
    if (uri == null || uri.host.isEmpty || uri.scheme != 'https') return;
    final hosts = <String>{
      uri.host,
      if (uri.host.startsWith('reader.')) uri.host.substring('reader.'.length),
    };
    final manager = CookieManager.instance();
    for (final host in hosts) {
      final url = WebUri('https://$host/');
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
  }

  /// O8: the reader holds the session in the WebView for as long as it
  /// is open (the site's own pages need it). Drop it when the reader
  /// goes away so a stale pair never outlives the reading session.
  /// Same hosts as [_installSessionCookiesOnce]: the reader host and
  /// its bare host. Best-effort — [deleteSessionCookies] never throws,
  /// so this is safe to fire from [dispose].
  Future<void> _clearSessionCookies() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null || uri.host.isEmpty) return;
    final hosts = <String>{
      uri.host,
      if (uri.host.startsWith('reader.')) uri.host.substring('reader.'.length),
    };
    for (final host in hosts) {
      await deleteSessionCookies(pageUrl: 'https://$host/');
    }
  }

  /// WebView → app 的会话回同步：站内登录（登录墙）或站点轮换密钥
  /// 都会把 WebView CookieStore 里的 remix 对改掉。读回后发现与本次
  /// 安装进来的对不一致，就上报 [ReaderArgs.onSessionChanged]，让
  /// app 层采纳新会话——否则下次打开预览会把旧会话盖回去，站点再
  /// 次弹登录墙，循环往复；下次冷启动还会因登录态失效被清掉凭据。
  Future<void> _syncSessionFromWebView(Uri pageUri) async {
    if (widget.onSessionChanged == null) return;
    if (pageUri.scheme != 'https' || pageUri.host.isEmpty) return;
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://${pageUri.host}/'),
      );
      String? userId;
      String? userKey;
      for (final cookie in cookies) {
        // Cookie.value is dynamic in flutter_inappwebview 6.1.5 — cast
        // once; strict-casts flags the bare assignments.
        final value = cookie.value as String?;
        if (value == null || value.isEmpty) continue;
        if (cookie.name == 'remix_userid') userId = value;
        if (cookie.name == 'remix_userkey') userKey = value;
      }
      if (userId == null || userKey == null) return;
      if (userId == _installedUserId && userKey == _installedUserKey) return;
      if (userId == _syncedUserId && userKey == _syncedUserKey) return;
      _syncedUserId = userId;
      _syncedUserKey = userKey;
      widget.onSessionChanged!(userId, userKey);
    } catch (error) {
      logIgnored('reader_screen', error);
    }
  }

  static String _probeUrl(Object? value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return '[non-http URL]';
    }
    final path = uri.pathSegments.map((segment) {
      if (RegExp(r'^[0-9]{1,10}$').hasMatch(segment)) return ':id';
      if (const {
        'api',
        'books',
        'quotes',
        'common-by-others',
      }.contains(segment)) {
        return segment;
      }
      return ':redacted';
    }).join('/');
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port/$path';
  }

  void _addProbe(Map<String, dynamic> entry) {
    if (!_probeEnabled) return;
    entry['t_ms'] = DateTime.now().difference(_probeStart).inMilliseconds;
    _probeLog.add(entry);
    if (kDebugMode) {
      AppLog.debug(
        '[LITERA_PROBE] ${jsonEncode(entry)}',
        tag: 'reader_screen',
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _shareProbeLog() async {
    final localizations = AppLocalizations.of(context)!;
    final entryCount = _probeLog.length;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/litera_probe_$ts.json');
      final payload = {
        'reader_url': _probeUrl(widget.url),
        'captured_at': DateTime.now().toIso8601String(),
        'entry_count': _probeLog.length,
        'entries': _probeLog,
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Litera Probe Log (${_probeLog.length} entries)',
          text: localizations.readerResourceLogCount(entryCount),
        ),
      );
    } catch (e) {
      if (mounted) {
        showAppSnack(context,
              AppLocalizations.of(context)!.readerLogExportFailed('$e'),
            );
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _routeAnimation) return;
    if (_routeAnimation != null && _routeAnimationListener != null) {
      _routeAnimation!.removeListener(_routeAnimationListener!);
    }
    _routeAnimation = animation;
    _routeAnimationListener = _onRouteAnimation;
    animation?.addListener(_routeAnimationListener!);
  }

  void _onRouteAnimation() {
    final animation = _routeAnimation;
    if (animation == null || !mounted) return;
    if (animation.status == AnimationStatus.reverse && !_webViewHidden) {
      setState(() {
        _webViewHidden = true;
      });
    } else if (animation.status == AnimationStatus.completed &&
        _webViewHidden) {
      setState(() {
        _webViewHidden = false;
      });
    }
  }

  @override
  void dispose() {
    if (_routeAnimation != null && _routeAnimationListener != null) {
      _routeAnimation!.removeListener(_routeAnimationListener!);
    }
    unawaited(_webViewController?.stopLoading());
    // O8: drop the session cookies installed for this reader session.
    unawaited(_clearSessionCookies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        actions: [
          if (_probeEnabled) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_probeLog.length}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: AppLocalizations.of(context)!
                .readerExportResourceLog,
              icon: const Icon(Icons.ios_share),
              onPressed: _probeLog.isEmpty ? null : _shareProbeLog,
            ),
          ],
          IconButton(
            tooltip: AppLocalizations.of(context)!.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => _webViewController?.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Visibility(
            visible: !_webViewHidden,
            maintainState: true,
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                allowFileAccess: false,
                allowContentAccess: false,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                supportZoom: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                useOnLoadResource: _probeEnabled,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onWebViewCreated: (controller) async {
                _webViewController = controller;
                // 先写会话 Cookie，再加载页面，避免首个请求不带鉴权。
                await _installSessionCookies();
                await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(widget.url)),
                );
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                if (uri == null || uri.host.isEmpty) {
                  return NavigationActionPolicy.CANCEL;
                }
                // 只处理 http(s)：intent:// 等其他 scheme 一律拒绝。
                final scheme = uri.scheme.toLowerCase();
                if (scheme != 'https' && scheme != 'http') {
                  return NavigationActionPolicy.CANCEL;
                }
                if (!_isAllowedHost(uri.host)) {
                  // 站外链接不在 WebView 里打开，避免带会话的页面被带走。
                  if (scheme == 'https') {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                  return NavigationActionPolicy.CANCEL;
                }
                // 站内也只放行 https，避免会话页面降级到明文。
                return scheme == 'https'
                    ? NavigationActionPolicy.ALLOW
                    : NavigationActionPolicy.CANCEL;
              },
              onCreateWindow: (controller, action) async {
                // window.open / target=_blank: same-site links stay in
                // this WebView (e.g. the authorize wall's Log In button);
                // only truly external hosts go to the system browser.
                final uri = action.request.url;
                if (uri == null) return false;
                final scheme = uri.scheme.toLowerCase();
                if (scheme != 'https' && scheme != 'http') return false;
                if (_isAllowedHost(uri.host)) {
                  await controller.loadUrl(
                    urlRequest: URLRequest(url: uri),
                  );
                  return true;
                }
                if (scheme == 'https') {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                return false;
              },
              onLoadStart: (controller, url) {
                setState(() {
                  _isLoading = true;
                });
                if (_probeEnabled) {
                  _addProbe({
                    'kind': 'load_start',
                    'url': _probeUrl(url),
                  });
                }
              },
              onLoadStop: (controller, url) {
                setState(() {
                  _isLoading = false;
                });
                if (_probeEnabled) {
                  _addProbe({
                    'kind': 'load_stop',
                    'url': _probeUrl(url),
                  });
                }
                // 每次页面加载完成都回读一次会话：站内登录/密钥轮换
                // 只发生在 WebView 侧，发现新会话就上报 app 采纳。
                if (url != null) {
                  unawaited(_syncSessionFromWebView(url));
                }
              },
              onProgressChanged: (controller, progress) {
                setState(() {
                  _progress = progress / 100;
                });
              },
              onLoadResource: _probeEnabled ? (controller, resource) {
                _addProbe({
                  'kind': 'resource',
                  'url': _probeUrl(resource.url),
                  'initiator': resource.initiatorType,
                  'duration_ms': resource.duration,
                });
              } : null,
              onReceivedError: (controller, request, error) {
                if (_probeEnabled) {
                  _addProbe({
                    'kind': 'error',
                    'url': _probeUrl(request.url),
                    'type': error.type.toString(),
                  });
                }
                AppLog.report(
                  'WebView error: ${error.type}',
                  tag: 'reader_screen',
                );
              },
            ),
          ),

          // Progress indicator
          if (_isLoading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Arguments for ReaderScreen
class ReaderArgs {
  final String url;
  final String title;

  /// Z-Library session, installed as WebView cookies before load.
  /// Never appended to the URL (query strings leak to JS / Referer / logs).
  final String? remixUserId;
  final String? remixUserKey;

  /// Fired when the WebView's cookie store ends up with a session pair
  /// different from the one installed here (the user signed in on the
  /// site's login wall inside the reader, or the site rotated the key).
  /// The route layer wires this to [AuthNotifier.adoptWebViewSession].
  final void Function(String userId, String userKey)? onSessionChanged;

  const ReaderArgs({
    required this.url,
    required this.title,
    this.remixUserId,
    this.remixUserKey,
    this.onSessionChanged,
  });
}
