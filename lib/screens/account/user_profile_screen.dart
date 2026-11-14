import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/challenge_html_cache.dart';
import '../../services/booklist_html_cache.dart';
import '../../services/wall_cookie_bridge.dart';
import '../../services/webview_challenge_solver.dart';
import '../../widgets/booklist_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/state_transition_switch.dart';
import '../../widgets/loading_widget.dart';
import '../comments/book_comments_screen.dart';
import 'booklist_detail_screen.dart';
import 'comment_book_ref_controller.dart';
import 'widgets/profile_widgets.dart';

import '../../utils/app_snack.dart';
import '../../widgets/entrance.dart';
/// Another user's profile page, reached by tapping an avatar in a
/// comment row. Header (avatar + name from the tapped comment),
/// then that user's booklists (from the profile document's
/// server-rendered booklists tab) and their posted comments (via
/// `getUserComments`, same endpoint order as "My Comments").
/// Their saved books are NOT shown: other users' profiles have no
/// library tab on the site, and `getUserSaved` reads the session
/// user only. The reading queue (`z-tab="plans"`) is NOT shown
/// either: its content was cut off in the capture and the app has
/// no reading-queue concept. Tapping a comment opens that book's
/// comments page; tapping its book-title row (cover thumbnail + title)
/// opens the book's detail page (the user-comments endpoint carries no
/// book hash, so it is resolved by a title search first — see
/// [_UserProfileScreenState._openBookDetail]); tapping a booklist
/// opens its detail page, with the carousel preview painting instantly.
class UserProfileScreen extends ConsumerStatefulWidget {
  final UserProfileArgs args;

  const UserProfileScreen({super.key, required this.args});

  @override
  ConsumerState<UserProfileScreen> createState() =>
      _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  List<UserCommentEntry> _entries = [];
  List<Booklist> _booklists = [];
  bool _isLoading = true;
  bool _loggedIn = true;
  bool _booklistsLoading = false;
  String? _booklistsError;

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
    final response =
        await api.getUserComments(_args.userId.toString());
    if (!mounted) return;
    setState(() {
      _entries = response.success && response.data != null
          ? response.data!.entries
          : const [];
      _isLoading = false;
    });
    unawaited(
      _bookRefController.prefetch(
        _entries
            .map((e) => (bookId: e.bookId, title: e.bookTitle))
            .toList(),
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
      onFail: () =>
          _showSnack(AppLocalizations.of(context)!.openBookFailed),
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
    final cachedHtml = BooklistHtmlCache.get(url);
    if (cachedHtml != null && !_isChallengeHtml(cachedHtml)) {
      setState(() {
        _booklists = parseUserProfileBooklists(
          cachedHtml,
          baseUrl: Uri.parse(url).origin,
        );
        _booklistsLoading = false;
        _booklistsError = null;
      });
      unawaited(_loadBooklists(backgroundRefresh: true));
      return;
    }
    await _loadBooklists();
  }

  /// The profile document's booklists tab, via the plugin. Skipped
  /// when the tapped comment carried no profile hash — the page then
  /// shows comments only. The profile page is an HTML route, so the
  /// mirror can wall Dio: on a browser-check error the WebView
  /// solver fetches the same page (the booklists screen's pattern).
  /// In background-refresh mode (cached rows on screen) the section
  /// keeps showing them: no loading row, and a failed refresh just
  /// leaves the cached rows in place.
  Future<void> _loadBooklists({bool backgroundRefresh = false}) async {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return;
    if (ref.read(authProvider).user == null) return;
    if (!backgroundRefresh) {
      setState(() {
        _booklistsLoading = true;
        _booklistsError = null;
      });
    }
    final api = ref.read(zlibraryApiProvider);
    try {
      final response = await api.getUserProfileBooklists(
        userId: _args.userId.toString(),
        userHash: hash,
      );
      if (!mounted) return;
      if (response.success && response.data != null) {
        setState(() {
          _booklists = response.data!;
          _booklistsLoading = false;
          _booklistsError = null;
        });
        return;
      }
      if (_isChallengeError(response.error)) {
        await _loadBooklistsViaSolver(
          hash,
          response.error ?? 'Failed to load booklists',
          backgroundRefresh: backgroundRefresh,
        );
        return;
      }
      if (backgroundRefresh) return;
      setState(() {
        _booklistsLoading = false;
        _booklistsError =
            response.error ?? 'Failed to load booklists';
      });
    } catch (e) {
      if (!mounted) return;
      if (backgroundRefresh) return;
      setState(() {
        _booklistsLoading = false;
        _booklistsError = e.toString();
      });
    }
  }

  /// Fetch the profile page through the WebView challenge solver and
  /// parse it with the plugin's [parseUserProfileBooklists]. The
  /// session cookies go into the WebView's CookieManager first (the
  /// booklist detail screen's pattern). A failure here reports the
  /// fast path's original error, so the retry button re-runs the
  /// whole fast-then-solver sequence.
  Future<void> _loadBooklistsViaSolver(
    String hash,
    String originalError, {
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
    final hasSession =
        user != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await _installSessionCookies(user!.id, userKey!, url);
    }
    try {
      var html = ChallengeHtmlCache.get(url);
      if (html != null && _isChallengeHtml(html)) {
        // A stale challenge page must not short-circuit the solve.
        html = null;
      }
      html ??= await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
      if (!mounted) return;
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
      setState(() {
        _booklists = parseUserProfileBooklists(
          pageHtml,
          baseUrl: Uri.parse(url).origin,
        );
        _booklistsLoading = false;
        _booklistsError = null;
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
      body: StateTransitionSwitch(
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
                      _sectionHeader(
                        l10n.comments,
                        _entries.length,
                      ),
                      ..._commentCards(),
                    ],
                  ),
                ),
              ),
    );
  }

  /// 头部统计的书单数：无书单区（评论没带 hash）或加载中/出错时
  /// 返回 null，头部就不显示书单药丸。
  int? get _booklistCount {
    final hash = _args.userHash;
    if (hash == null || hash.isEmpty) return null;
    if (_booklistsLoading || _booklistsError != null) return null;
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
        _booklistsLoading || _booklistsError != null
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
    }
    return children;
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
          TextButton(
            onPressed: _loadBooklists,
            child: Text(l10n.retry),
          ),
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
        EntranceSlideFade(
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
