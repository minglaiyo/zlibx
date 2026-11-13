import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../screens/comments/book_comments_screen.dart';
import '../../screens/comments/widgets/comment_avatar.dart';
import '../../screens/comments/widgets/comment_metric_chip.dart';
import '../../utils/app_snack.dart';
import '../../utils/date_text.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/entrance.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/state_transition_switch.dart';
import 'comment_book_ref.dart';
import 'comment_book_ref_controller.dart';
/// One comment the signed-in user posted, as shown on the website's
/// profile "Comments" tab: which book it was on, the text, when, and
/// how many likes it has.
class MyComment {
  final int id;
  final int bookId;
  final String bookTitle;
  final String text;
  final String date;
  final int likeCount;
  final int userId;
  final String userAvatar;
  final String userHash;

  const MyComment({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.text,
    required this.date,
    this.likeCount = 0,
    required this.userId,
    this.userAvatar = '',
    this.userHash = '',
  });
}

/// My comments arrive in server order, oldest first — the comments
/// endpoints have no sort parameter, same as the book comments list.
/// The screen shows newest first, so the server order is reversed.
/// The displayed date is a relative string (e.g. "3 days ago"), so
/// there is nothing to parse; reversal is the whole sort.
List<MyComment> orderMyCommentsNewestFirst(List<MyComment> serverOrder) =>
    serverOrder.reversed.toList();

/// "My Comments": the signed-in user's own posted comments, the same
/// collection the website shows on the profile Comments tab
/// (`GET /papi/comments/user/{userId}/{page}?limit=500`, confirmed by a
/// packet capture on 2026-11-06). Tapping a comment opens that book's
/// comments page; tapping the book-title row (cover thumbnail + title)
/// opens the book's detail page (the user-comments API carries no book
/// hash, so it is resolved by a title search first — see
/// [CommentBookRefController.openBookDetail]).
/// Deleting is wired: `DELETE /papi/comments/delete/{commentId}`,
/// confirmed by a packet capture on 2026-11-09.
class MyCommentsScreen extends ConsumerStatefulWidget {
  const MyCommentsScreen({super.key});

  @override
  ConsumerState<MyCommentsScreen> createState() => _MyCommentsScreenState();
}

class _MyCommentsScreenState extends ConsumerState<MyCommentsScreen> {
  List<MyComment> _comments = [];
  bool _isLoading = true;
  bool _loggedIn = true;

  /// 书名行的封面预取 + 跳详情（与用户主页共用，见
  /// [CommentBookRefController]）。
  late final CommentBookRefController _bookRefController;

  @override
  void initState() {
    super.initState();
    _bookRefController = CommentBookRefController(
      api: ref.read(zlibraryApiProvider),
    )..addListener(_onBookRefsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
    List<MyComment> comments = const [];
    try {
      final response = await api.getMyComments();
      if (response.success && response.data != null) {
        comments = response.data!.entries
            .map((e) => MyComment(
                  id: e.comment.id,
                  bookId: e.bookId,
                  bookTitle: e.bookTitle,
                  text: e.comment.text,
                  date: commentDateText(
                    e.comment.dateRelative,
                    e.comment.date,
                  ),
                  likeCount: e.comment.likeCount,
                  userId: e.comment.userId,
                  userAvatar: e.comment.userAvatar,
                  userHash: e.comment.userHash,
                ))
            .toList();
      }
    } catch (error) {
      // 失败按空列表处理，下拉重试
      logIgnored('my_comments', error);
    }
    // 服务器按最旧在前返回；列表按最新在前展示。
    comments = orderMyCommentsNewestFirst(comments);
    if (!mounted) return;
    setState(() {
      _comments = comments;
      _isLoading = false;
    });
    unawaited(
      _bookRefController.prefetch(
        _comments
            .map((c) => (bookId: c.bookId, title: c.bookTitle))
            .toList(),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnack(context, message);
  }

  // --------------------------------------------------------------- 导航

  void _openComments(MyComment comment) {
    AppRoutes.openBookComments(
      context,
      BookCommentsArgs(
        bookId: comment.bookId,
        bookTitle: comment.bookTitle,
      ),
    );
  }

  void _openProfile(MyComment comment) {
    final userName = ref.read(authProvider).user?.name ?? '';
    AppRoutes.openUserProfile(
      context,
      UserProfileArgs(
        userId: comment.userId,
        userName: userName,
        userAvatar: comment.userAvatar,
        userHash: comment.userHash,
      ),
    );
  }

  /// 书名行 → 书籍详情：hash 反查、防重点与失败提示都在
  /// [CommentBookRefController]（与用户主页共用），屏侧只负责导航。
  Future<void> _openBookDetail(MyComment comment) async {
    await _bookRefController.openBookDetail(
      bookId: comment.bookId,
      title: comment.bookTitle,
      onReady: (book) {
        if (!mounted) return;
        AppRoutes.openBookDetailForBook(context, book);
      },
      onFail: () =>
          _showSnack(AppLocalizations.of(context)!.openBookFailed),
    );
  }

  /// 删自己的评论：先弹确认框（破坏性操作），确认后乐观移除；
  /// 失败时把评论放回原位并提示。
  Future<void> _confirmDelete(MyComment comment) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.commentDeleteConfirm),
        content: Text(l10n.commentDeleteDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    final index = _comments.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    final removed = _comments[index];
    setState(() => _comments.removeAt(index));
    try {
      final response = await ref
          .read(zlibraryApiProvider)
          .deleteBookComment(comment.id);
      if (!mounted) return;
      if (!response.success) {
        setState(
          () => _comments.insert(index.clamp(0, _comments.length), removed),
        );
        _showSnack(l10n.commentDeleteFailed);
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _comments.insert(index.clamp(0, _comments.length), removed),
      );
      _showSnack(l10n.commentDeleteFailed);
    }
  }

  // --------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    Widget body;
    if (_isLoading) {
      body = LoadingWidget(
        key: const ValueKey('loading'),
        message: l10n.loading,
      );
    } else if (!_loggedIn) {
      body = EmptyState(
        key: const ValueKey('login'),
        icon: Icons.login_rounded,
        title: l10n.loginToViewComments,
        action: FilledButton(
          onPressed: () => AppRoutes.openLogin(context),
          child: Text(l10n.login),
        ),
      );
    } else if (_comments.isEmpty) {
      body = EmptyState(
        key: const ValueKey('empty'),
        icon: Icons.comment_outlined,
        title: l10n.noComments,
      );
    } else {
      body = RefreshIndicator(
        key: const ValueKey('list'),
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
          itemCount: _comments.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final comment = _comments[index];
            final userName = ref.read(authProvider).user?.name ?? '';
            return EntranceSlideFade(
              index: index,
              child: _MyCommentCard(
                comment: comment,
                userName: userName,
                coverUrl:
                    _bookRefController.refFor(comment.bookId)?.cover ?? '',
                isOpeningBook:
                    _bookRefController.isOpening(comment.bookId),
                onCardTap: () => _openComments(comment),
                onBookTap: () => _openBookDetail(comment),
                onAvatarTap: () => _openProfile(comment),
                onDelete: () => _confirmDelete(comment),
                deleteTooltip: l10n.delete,
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: GradientAppBar(title: l10n.myComments),
      // loading → 登录态 → 空态 → 列表：统一淡入淡出（此前硬切）。
      body: StateTransitionSwitch(child: body),
    );
  }
}

/// 卡片化的一条“我的评论”，与书籍评论区同一套视觉语言：
/// 书名行（封面缩略图 + 书名，点击 → 书籍详情）+ 头像/昵称/正文/
/// 日期与点赞数。点卡片其余区域进入该书的评论区。
class _MyCommentCard extends StatelessWidget {
  final MyComment comment;
  final String userName;

  /// 书名行的封面 URL；空串显示占位图（hash/封面未解析到）。
  final String coverUrl;

  /// 书 hash 解析中：书名行尾显示转圈并禁止再次点击。
  final bool isOpeningBook;
  final VoidCallback onCardTap;
  final VoidCallback onBookTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onDelete;
  final String deleteTooltip;

  const _MyCommentCard({
    required this.comment,
    required this.userName,
    required this.coverUrl,
    required this.isOpeningBook,
    required this.onCardTap,
    required this.onBookTap,
    required this.onAvatarTap,
    required this.onDelete,
    required this.deleteTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onCardTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 书名行 → 书籍详情（内层命中优先于卡片）。
                CommentBookTile(
                  title: comment.bookTitle,
                  coverUrl: coverUrl,
                  busy: isOpeningBook,
                  onTap: onBookTap,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CommentAvatar(
                      avatarUrl: comment.userAvatar,
                      onTap: onAvatarTap,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            userName,
                            style: tt.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (comment.text.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            SelectableText(
                              comment.text,
                              style: tt.bodyMedium?.copyWith(height: 1.45),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text(
                                comment.date,
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 6),
                              CommentMetricChip(
                                // 描边图标：与评论区一致，填充态专指已点赞；
                                // 这里纯展示自己的获赞数。
                                icon: Icons.thumb_up_outlined,
                                count: comment.likeCount,
                                // 纯展示：我的评论页不支持点赞切换。
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: onDelete,
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                ),
                                iconSize: 20,
                                tooltip: deleteTooltip,
                                visualDensity: VisualDensity.compact,
                                color: cs.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
