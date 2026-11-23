import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/booklist_html_cache.dart';
import '../../services/challenge_html_cache.dart';
import '../../services/wall_cookie_bridge.dart';
import '../../services/webview_challenge_solver.dart';
import '../../utils/app_snack.dart';
import '../../widgets/booklist_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/motion/motion.dart';
import '../comments/book_comments_screen.dart';
import 'booklist_detail_screen.dart';
import 'comment_book_ref_controller.dart';
import 'widgets/profile_widgets.dart';


/// Another user's profile page, reached by tapping an avatar in a
/// comment row. Header (avatar + name from the tapped comment),
/// then that user's booklists and their posted comments (via
/// `getUserComments`, same endpoint order as "My Comments").
/// The booklists come from the profile document's server-rendered
/// booklists tab, which carries at most 10 lists — users with more
/// get the next page only when they ask for it ("load more" at the
/// tail; issue #11, issue #34): page 1 paints first, each further
/// page is fetched on demand from the paginated route
/// (`/profile/{id}/{hash}/booklists?page=N`) and appended. A failed
/// page keeps the loaded rows and offers a retry for that same page.
/// Their saved books are NOT shown: other users'
/// profiles have no library tab on the site, and `getUserSaved` reads
/// the session user only. The reading queue (`z-tab="plans"`) is NOT
/// shown either: its content was cut off in the capture and the app
/// has no reading-queue concept. Tapping a comment opens that book's
/// comments page; tapping its book-title row (cover thumbnail + title)
/// opens the book's detail page (the user-comments endpoint carries no
/// book hash, so it is resolved by a title search first — see
/// [_UserProfileScreenState._openBookDetail]); tapping a booklist
/// opens its detail page, with the carousel preview painting instantly.
class UserProfileScreen extends ConsumerStatefulWidget {
  final UserProfileArgs args;

  const UserProfileScreen({super.key, required this.args});

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  List<UserCommentEntry> _entries = [];
  List<Booklist> _booklists = [];
  bool _isLoading = true;
  bool _loggedIn = true;
  bool _booklistsLoading = false;

  /// 下一页按需加载进行中（第 1 页已上屏，区块尾部的加载行靠它
  /// 显示；一次只拉一页）。
  bool _booklistsPaging = false;

  /// 下一次按需加载要拉的页码（null = 没有更多页：第 1 页或上一
  /// 次拉到的页不满 10 个、拉到空页，或已到 [_maxBooklistPages]
  /// 上限）。第 1 页满 10 个时置为 2，尾部“加载更多”提供它；拉到
  /// 一页后按是否满页推进，失败时保持不动（重试拉同一页）。
  int? _booklistsNextPage;

  /// 上一次按需拉页的错误（null = 无错误）：与 [_booklistsError]
  /// （第 1 页）分开，免得一页失败把整个区块打回错误态——已加载
  /// 的行留着，尾部只对这一页出重试行。
  String? _booklistsPageError;
  String? _booklistsError;

  /// 书单分页加载的代数：每次 [_loadBooklists] 启动时递增，分页
  /// 循环的每次续接前校验——下拉刷新/重试叠上来时，旧加载在下一页
  /// 边界安静退场，不会把陈旧的行并进新列表。
  int _booklistsEpoch = 0;

  /// 分页循环的页数上限（防御值）：分页器给出真实页数，正常远小于
  /// 此值；一个 200 页（2000 个书单）的极端档案也只拉 200 个轻量
  /// HTML 文档。
  static const int _maxBooklistPages = 200;

  /// 评论书名行的封面预取 + 跳详情（与我的评论页共用，见
  /// [CommentBookRefController]）。
  late final CommentBookRefController _bookRefController;

  UserProfileArgs get _args => widget.args;

  @override
  void initState() {
    super.initState();
    _bookRefController = CommentBookRefController(
      api: ref.read(zlibraryApiProvider),
    )..addListener(_onBookRefsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadBooklistsCachedFirst();
    });
  }

  void _onBookRefsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bookRefController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (ref.read(authProvider).user == null) {
      setState(() {
        _loggedIn = false;
        _isLoading = false;
      });
      return;
    }
    setState(() => _isLoading = true);
    final api = ref.read(zlibraryApiProvider);
    final response = await api.getUserComments(_args.userId.toString());
    if (!mounted) return;
    setState(() {
      _entries = response.success && response.data != null
          ? response.data!.entries
          : const [];
      _isLoading = false;
    });
    unawaited(
      _bookRefController.prefetch(
        _entries.map((e) => (bookId: e.bookId, title: e.bookTitle)).toList(),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnack(context, message);
  }

  /// 书名行 → 书籍详情：hash 反查、防重点与失败提示都在
  /// [CommentBookRefController]（与我的评论页共用），屏侧只负责导航。
  Future<void> _openBookDetail(UserCommentEntry entry) async {
    await _bookRefController.openBookDetail(
      bookId: entry.bookId,
      title: entry.bookTitle,
      onReady: (book) {
        if (!mounted) return;
        AppRoutes.openBookDetailForBook(context, book);
      },
      onFail: () => _showSnack(AppLocalizations.of(context)!.openBookFailed),
    );
  }

  /// Pull-to-refresh reloads both sections. The booklists load is
  /// not awaited here: it has its own loading state inside the
  /// section, and its solver fallback can take a while.
  Future<void> _refresh() async {
    unawaited(_loadBooklists());
    await _load();
  }

  /// Paint the last-known booklists from the persistent cache, then
  /// refresh in the background (stale-while-revalidate). Without a
  /// cached page this is exactly the existing foreground load.
  Future<void> _loadBooklistsCachedFirst() async {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return;
    if (ref.read(authProvider).user == null) return;
    final api = ref.read(zlibraryApiProvider);
    final url = api.userProfilePageUrl(
      userId: _args.userId.toString(),
      userHash: hash,
    );
    final cachedHtml = await BooklistHtmlCache.get(url);
    if (cachedHtml != null && !_isChallengeHtml(cachedHtml)) {
      // Phase 3: parse through the Rust bridge when injected (await
      // before setState — the parse is a Future under the hook).
      final lists = await parseUserProfileBooklistsH(
        cachedHtml,
        baseUrl: Uri.parse(url).origin,
      );
      if (!mounted) return;
      setState(() {
        _booklists = lists;
        _booklistsLoading = false;
        _booklistsError = null;
      });
      unawaited(_loadBooklists(backgroundRefresh: true));
      return;
    }
    await _loadBooklists();
  }

  /// The profile document's booklists tab, via the plugin. Page 1
  /// paints as soon as it lands; further pages are NOT auto-fetched
  /// (load-on-demand, issue #34: auto-fetching 71 pages at once is
  /// part of why the wall hits so often) — a full page 1 arms the
  /// tail "load more" row ([_booklistsNextPage] = 2), and each tap
  /// loads exactly one more page ([_loadBooklistNextPage]). Skipped
  /// when the tapped comment carried no profile hash — the page then
  /// shows comments only. The profile page is an HTML route, so the
  /// mirror can wall Dio: on a browser-check error the WebView solver
  /// fetches the same page (the booklists screen's pattern). In
  /// background-refresh mode (cached rows on screen) the section
  /// keeps showing them: no loading row, and a failed refresh just
  /// leaves the cached rows in place.
  Future<void> _loadBooklists({bool backgroundRefresh = false}) async {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return;
    if (ref.read(authProvider).user == null) return;
    if (!backgroundRefresh) {
      setState(() {
        _booklistsLoading = true;
        // 新一次加载把上一轮的分页加载行清掉：旧分页循环退出时不重置
        // 的话，这轮若只有 1 页就没人再碰这个旗标，卡尾的加载行会
        // 卡在屏上（epoch 守卫只保护数据，不保护 UI 旗标）。按需
        // 加载的下一页和页错误也一起清掉，免得旧的“加载更多”/重试
        // 行叠在新一轮第 1 页下面。
        _booklistsPaging = false;
        _booklistsNextPage = null;
        _booklistsPageError = null;
        _booklistsError = null;
      });
    }
    final api = ref.read(zlibraryApiProvider);
    final epoch = ++_booklistsEpoch;
    try {
      final response = await api.getUserProfileBooklists(
        userId: _args.userId.toString(),
        userHash: hash,
      );
      if (!mounted || epoch != _booklistsEpoch) return;
      if (response.success && response.data != null) {
        setState(() {
          _booklists = response.data!.lists;
          _booklistsLoading = false;
          _booklistsError = null;
          // 旧的页错误随新一轮第 1 页清掉（后台刷新不走上面的
          // setState，也要清）。
          _booklistsPageError = null;
          // 第 1 页满 10 个才可能有第 2 页：不满一页就是最后一页，
          // 尾部不出“加载更多”。满 10 个也可能是正好 10 个，点
          // “加载更多”拉到空页时再收掉。
          _booklistsNextPage =
              response.data!.lists.length >= 10 ? 2 : null;
        });
        return;
      }
      if (_isChallengeError(response.error)) {
        await _loadBooklistsViaSolver(
          hash,
          response.error ?? 'Failed to load booklists',
          epoch,
          backgroundRefresh: backgroundRefresh,
        );
        return;
      }
      if (backgroundRefresh) return;
      setState(() {
        _booklistsLoading = false;
        _booklistsError = response.error ?? 'Failed to load booklists';
      });
    } catch (e) {
      if (!mounted || epoch != _booklistsEpoch) return;
      if (backgroundRefresh) return;
      setState(() {
        _booklistsLoading = false;
        _booklistsError = e.toString();
      });
    }
  }

  /// Load exactly one more booklists page on demand (the tail
  /// "load more" row calls this). Fetches [_booklistsNextPage] once
  /// and appends it; the tail then offers the following page, or
  /// closes when this page proves to be the last one.
  ///
  /// The loop does NOT stop at the page-1 total: the site's
  /// booklists paginator is a sliding window (page 1 shows 1–10, no
  /// Last link), so the total read off page 1 is only a lower bound
  /// (issue #34: a 71-page profile reads as 10 from page 1). A page
  /// is the last one when it is empty (past the end, e.g. the list
  /// shrank between fetches) or partial (< 10 lists), capped at
  /// [_maxBooklistPages]. The pages are NOT cached: the SWR cache
  /// only holds the profile document (page 1).
  ///
  /// A failed page does NOT wipe the section: the loaded rows stay
  /// and the tail shows a retry row for this same page
  /// ([_booklistsNextPage] is untouched, so retry re-requests it —
  /// the Mihon pattern: keep content, retry the same page). [epoch]
  /// is the generation captured at entry — a pull-refresh or retry
  /// that started later wins, and this load exits silently.
  Future<void> _loadBooklistNextPage() async {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return;
    final nextPage = _booklistsNextPage;
    if (nextPage == null || _booklistsPaging) return;
    final api = ref.read(zlibraryApiProvider);
    final epoch = _booklistsEpoch;
    setState(() {
      _booklistsPaging = true;
      _booklistsPageError = null;
    });
    try {
      final result = await _fetchBooklistPage(api, hash, nextPage, epoch);
      if (!mounted || epoch != _booklistsEpoch) return;
      if (result.error != null) {
        // 这一页拉不到（非墙失败，或解墙也失败）：保留已加载的行，
        // 尾部出重试行，下一页码不动，点重试就重拉这一页。
        setState(() {
          _booklistsPaging = false;
          _booklistsPageError = result.error;
        });
        return;
      }
      final fresh = result.lists ?? const <Booklist>[];
      if (fresh.isEmpty) {
        // 空页 = 已经过了最后一页，收掉“加载更多”。
        setState(() {
          _booklistsPaging = false;
          _booklistsNextPage = null;
        });
        return;
      }
      setState(() {
        _booklistsPaging = false;
        // 按 id 去重：两页之间书单被增删时，分页可能整体位移，
        // 重复行宁缺勿双。
        final seen = _booklists.map((l) => l.id).toSet();
        _booklists = [
          ..._booklists,
          ...fresh.where((l) => !seen.contains(l.id)),
        ];
        // 不满一页（< 10 个）就是最后一页；满页则可能还有下一页
        // （上限 [_maxBooklistPages]）。
        _booklistsNextPage =
            fresh.length < 10 || nextPage >= _maxBooklistPages
            ? null
            : nextPage + 1;
      });
    } on Object catch (e) {
      // 异常也只坏这一页：行留着，尾部出重试行。
      if (!mounted || epoch != _booklistsEpoch) return;
      setState(() {
        _booklistsPaging = false;
        _booklistsPageError = e.toString();
      });
    }
  }

  /// One paginated profile-booklists page (page ≥ 2): fast Dio first;
  /// on a browser-check wall, fall back to the WebView solver for
  /// that page (the booklist detail page's pattern). Returns the
  /// page's lists, an empty list when past the end, or an error when
  /// the page could not be loaded (a non-wall failure, or the solve
  /// failed — the caller shows it in the per-page retry row). A solve
  /// bridges the fresh wall cookies to Dio, so the next page tries
  /// Dio first again.
  Future<({List<Booklist>? lists, String? error})> _fetchBooklistPage(
    ZLibraryApi api,
    String hash,
    int page,
    int epoch,
  ) async {
    final response = await api.getUserProfileBooklistsPage(
      userId: _args.userId.toString(),
      userHash: hash,
      page: page,
    );
    if (response.success && response.data != null) {
      return (lists: response.data!, error: null);
    }
    if (!_isChallengeError(response.error)) {
      return (
        lists: null,
        error: response.error ?? 'Failed to load booklists',
      );
    }
    final solved = await _fetchBooklistPageViaSolver(api, hash, page, epoch);
    if (solved == null) {
      return (
        lists: null,
        error: response.error ?? 'Failed to load booklists',
      );
    }
    return (lists: solved, error: null);
  }

  /// One paginated profile-booklists page through the WebView
  /// challenge solver. Mirrors [_loadBooklistsViaSolver] (install
  /// session, solve, bridge, parse, O8 cleanup) but for a single
  /// page and without caching — the app only re-reads the profile
  /// document (page 1) from cache, so caching page-N documents
  /// would just be dead data. Returns null when the solve failed
  /// or the page is still a challenge page.
  Future<List<Booklist>?> _fetchBooklistPageViaSolver(
    ZLibraryApi api,
    String hash,
    int page,
    int epoch,
  ) async {
    final url = api.userProfileBooklistsPageUrl(
      userId: _args.userId.toString(),
      userHash: hash,
      page: page,
    );
    final user = ref.read(authProvider).user;
    final userKey = user?.remixUserkey;
    final hasSession = user != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await _installSessionCookies(user.id, userKey, url);
    }
    try {
      final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
      if (!mounted || epoch != _booklistsEpoch) return null;
      if (html == null || html.isEmpty || _isChallengeHtml(html)) {
        return null;
      }
      // The solve earned wall-clearance cookies — hand them to Dio so
      // the next page tries the fast path first.
      await bridgeWallCookies(api, url);
      if (!mounted || epoch != _booklistsEpoch) return null;
      return parseUserProfileBooklistsH(
        html,
        baseUrl: Uri.parse(url).origin,
      );
    } finally {
      // O8: the session only lives for this solve.
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }

  /// Fetch the profile page through the WebView challenge solver and
  /// parse it with the plugin's [parseUserProfileBooklists]. The
  /// session cookies go into the WebView's CookieManager first (the
  /// booklist detail screen's pattern). A failure here reports the
  /// fast path's original error, so the retry button re-runs the
  /// whole fast-then-solver sequence. On success the remaining pages
  /// load over Dio (the solve just cleared the wall cookies — see
  /// [bridgeWallCookies] — so they take the fast path).
  Future<void> _loadBooklistsViaSolver(
    String hash,
    String originalError,
    int epoch, {
    bool backgroundRefresh = false,
  }) async {
    final api = ref.read(zlibraryApiProvider);
    final url = api.userProfilePageUrl(
      userId: _args.userId.toString(),
      userHash: hash,
    );
    // When this fetch started, for the invalidation check on the
    // store below (see BooklistHtmlCache).
    final fetchedAt = DateTime.now();
    final user = ref.read(authProvider).user;
    final userKey = user?.remixUserkey;
    final hasSession = user != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await _installSessionCookies(user.id, userKey, url);
    }
    try {
      var html = ChallengeHtmlCache.get(url);
      if (html != null && _isChallengeHtml(html)) {
        // A stale challenge page must not short-circuit the solve.
        html = null;
      }
      html ??= await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
      if (!mounted || epoch != _booklistsEpoch) return;
      if (html == null || html.isEmpty || _isChallengeHtml(html)) {
        if (backgroundRefresh) return;
        setState(() {
          _booklistsLoading = false;
          _booklistsError = originalError;
        });
        return;
      }
      // `html` is a mutable local captured by the setState closure
      // below, so its null-check promotion does not survive into the
      // closure — pin it to a final first.
      final pageHtml = html;
      // The solve earned wall-clearance cookies — hand them to Dio so
      // the next HTML load skips the solver. The solved page also goes
      // into the persistent cache so the next open paints it instantly.
      await bridgeWallCookies(api, url);
      if (!mounted) return;
      BooklistHtmlCache.store(url, pageHtml, fetchedAt: fetchedAt);
      final lists = await parseUserProfileBooklistsH(
        pageHtml,
        baseUrl: Uri.parse(url).origin,
      );
      if (!mounted || epoch != _booklistsEpoch) return;
      setState(() {
        _booklists = lists;
        _booklistsLoading = false;
        _booklistsError = null;
        _booklistsPageError = null;
        // 第 1 页满 10 个才可能有第 2 页（与 _loadBooklists 相同的
        // 守卫）：按需加载，尾部“加载更多”提供它，不自动往下探。
        _booklistsNextPage = lists.length >= 10 ? 2 : null;
      });
    } finally {
      // O8: the session only lives for this solve (see BooklistSolver).
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }

  /// The plugin's short error for a browser-check wall
  /// ('HTTP 503: browser check page'), plus the older shapes a wall can
  /// surface as, so the solver fallback triggers on any of them.
  bool _isChallengeError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('browser check') ||
        lower.contains('checking your browser') ||
        lower.contains('ddos-guard') ||
        lower.contains('cf_blocked') ||
        lower.contains('cf-challenge');
  }

  /// The solver only completes on real pages, but a cached page can be
  /// a stale challenge page — never parse one as an (empty) booklists
  /// page.
  bool _isChallengeHtml(String html) =>
      WebviewChallengeSolver.isChallengeHtml(html);

  /// Install the `remix_userid` / `remix_userkey` session into the
  /// WebView's CookieManager for the profile page's host (the reader's
  /// pattern — the manager is global on Android, so the solver's
  /// headless WebView sees them). Never put the keys in a URL.
  Future<void> _installSessionCookies(
    String userId,
    String userKey,
    String pageUrl,
  ) async {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final args = _args;

    return Scaffold(
      appBar: GradientAppBar(title: args.userName),
      // loading → 登录态 → 内容：统一淡入淡出（此前硬切）。
      body: MotionSwitch(
        child: _isLoading
            ? LoadingWidget(
                key: const ValueKey('loading'),
                message: l10n.loading,
              )
            : !_loggedIn
            ? EmptyState(
                key: const ValueKey('login'),
                icon: Icons.login_rounded,
                title: l10n.loginToViewComments,
                action: FilledButton(
                  onPressed: () => AppRoutes.openLogin(context),
                  child: Text(l10n.login),
                ),
              )
            : RefreshIndicator(
                key: const ValueKey('content'),
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                  children: [
                    ProfileHeader(
                      args: args,
                      commentCount: _entries.length,
                      booklistCount: _booklistCount,
                    ),
                    ..._booklistsSection(),
                    _sectionHeader(l10n.comments, _entries.length),
                    ..._commentCards(),
                  ],
                ),
              ),
      ),
    );
  }

  /// 头部统计的书单数：无书单区（评论没带 hash）、加载中/分页中、
  /// 出错时，或还没拉完（[_booklistsNextPage] 非空，当前数只是已
  /// 加载的部分数）时返回 null，头部就不显示书单药丸（分页中显示
  /// 部分数会先报小再跳大，不如等齐了一次到位；按需加载下，不点
  /// “加载更多”就永远不知道总数，藏着比报小更诚实）。
  int? get _booklistCount {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return null;
    if (_booklistsLoading ||
        _booklistsPaging ||
        _booklistsError != null ||
        _booklistsNextPage != null) {
      return null;
    }
    return _booklists.length;
  }

  Widget _sectionHeader(String title, int? count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        count == null ? title : '$title ($count)',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  /// The booklists section: header + rows, a loading row while the
  /// profile document loads, a short line when the user has none,
  /// and an error row with a retry button when both the fast path
  /// and the solver failed. Empty when the tapped comment carried
  /// no profile hash — the page then shows comments only.
  List<Widget> _booklistsSection() {
    final l10n = AppLocalizations.of(context)!;
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return const [];
    final children = <Widget>[
      _sectionHeader(
        l10n.booklists,
        _booklistsLoading ||
                _booklistsPaging ||
                _booklistsError != null ||
                _booklistsNextPage != null
            ? null
            : _booklists.length,
      ),
    ];
    if (_booklistsLoading) {
      children.add(const LoadingWidget.more());
    } else if (_booklistsError != null) {
      children.add(_booklistsErrorRow());
    } else if (_booklists.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            l10n.noBooklists,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    } else {
      // 书单分组成一张圆角卡：行间细分隔线，与评论卡片同一套语言。
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < _booklists.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  BooklistRow(
                    list: _booklists[i],
                    onTap: () => AppRoutes.openBooklistDetail(
                      context,
                      BooklistDetailArgs(booklist: _booklists[i]),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      // 尾部三态（按需加载）：下一页加载中 → 细加载行；上一页拉
      // 失败 → 重试行（行留着，重拉同一页）；还可能有下一页 →
      // “加载更多”按钮；拉完了 → 什么都不加。
      if (_booklistsPaging) {
        children.add(const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: LoadingWidget.more(),
        ));
      } else if (_booklistsPageError != null) {
        children.add(_booklistsPageErrorRow());
      } else if (_booklistsNextPage != null) {
        children.add(_booklistsLoadMoreRow());
      }
    }
    return children;
  }

  /// "Load more" tail row: offers the next booklists page on demand.
  /// Shown only when a further page may exist (the last fetched page
  /// was full) and no page fetch is in flight or failed.
  Widget _booklistsLoadMoreRow() {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Center(
        child: TextButton(
          onPressed: _loadBooklistNextPage,
          child: Text(l10n.loadMore),
        ),
      ),
    );
  }

  /// Per-page failure tail row: the loaded rows stay, and retry
  /// re-requests the same page ([_booklistsNextPage] is untouched).
  /// Same row language as the section error row above.
  Widget _booklistsPageErrorRow() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _booklistsPageError ?? l10n.error,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _loadBooklistNextPage,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _booklistsErrorRow() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _booklistsError ?? l10n.error,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(onPressed: _loadBooklists, child: Text(l10n.retry)),
        ],
      ),
    );
  }

  /// The comment cards, 12 px apart like "My Comments" — or a single
  /// short line when the user has posted none (a full empty state
  /// would hide the booklists above).
  List<Widget> _commentCards() {
    if (_entries.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            l10n.noComments,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    final args = _args;
    final cards = <Widget>[];
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (i > 0) cards.add(const SizedBox(height: 12));
      cards.add(
        MotionEntrance(
          index: i,
          child: ProfileCommentCard(
            entry: entry,
            userName: args.userName,
            coverUrl: _bookRefController.refFor(entry.bookId)?.cover ?? '',
            isOpeningBook: _bookRefController.isOpening(entry.bookId),
            onCardTap: () => AppRoutes.openBookComments(
              context,
              BookCommentsArgs(
                bookId: entry.bookId,
                bookTitle: entry.bookTitle,
              ),
            ),
            onBookTap: () => _openBookDetail(entry),
          ),
        ),
      );
    }
    return cards;
  }
}
