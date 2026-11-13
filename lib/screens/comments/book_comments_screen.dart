import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/confirm_dialog.dart';
import 'controllers/book_comments_controller.dart';
import 'widgets/book_context_header.dart';
import 'widgets/comment_composer.dart';
import 'widgets/comment_list.dart';

import '../../utils/app_snack.dart';
/// Arguments for BookCommentsScreen
class BookCommentsArgs {
  final int bookId;
  final String bookTitle;

  const BookCommentsArgs({
    required this.bookId,
    required this.bookTitle,
  });
}

/// Book comments — view, post, reply and like.
///
/// 逻辑在 [BookCommentsController]；这里只负责接 provider、组装
/// 上下文条 / 状态视图 / 列表 / 输入区，并发起导航与聚焦。
/// 需要登录会话，未登录显示登录入口。详见 controller 文档。
class BookCommentsScreen extends ConsumerStatefulWidget {
  final BookCommentsArgs args;

  const BookCommentsScreen({super.key, required this.args});

  @override
  ConsumerState<BookCommentsScreen> createState() =>
      _BookCommentsScreenState();
}

class _BookCommentsScreenState extends ConsumerState<BookCommentsScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _composerController = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  BookCommentsController? _controller;

  BookCommentsController get _c => _controller!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final args = widget.args;
    final l10n = AppLocalizations.of(context)!;
    _controller = BookCommentsController(
      bookId: args.bookId,
      api: ref.read(zlibraryApiProvider),
      commentFailed: l10n.commentFailed,
      likeFailed: l10n.likeFailed,
      commentDeleteFailed: l10n.commentDeleteFailed,
      onNotice: _showSnack,
    );
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _c.loadFirst(
        signedIn: ref.read(authProvider).user != null,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _scrollController.dispose();
    _composerController.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 300) _c.showMore();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnack(context, message);
  }

  bool get _signedIn => ref.read(authProvider).user != null;

  Future<void> _reload() => _c.loadFirst(signedIn: _signedIn);

  Future<void> _submit() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _c.isPosting) return;
    // 服务端要求评论至少 4 个字符；过短的 1–3 字符直接在前端拦掉，
    // 不发请求，免得服务端拒绝后只剩一句笼统的“评论发布失败”。
    if (text.length <= 3) {
      _showSnack(AppLocalizations.of(context)!.commentTooShort);
      return;
    }
    final wasReply = _c.replyTo != null;
    final posted = await _c.submit(text);
    if (!mounted) return;
    if (posted) {
      _composerController.clear();
      _composerFocus.unfocus();
      // 新顶层评论插在最前，滚回顶部让用户立刻看到自己的评论；
      // 回复则原地不动（父评论就在视口附近）。
      if (!wasReply && _scrollController.hasClients) {
        unawaited(_scrollController.animateTo(
          0,
          duration: AppMotion.slower,
          curve: Curves.easeOutCubic,
        ));
      }
    }
  }

  void _openProfile(BookComment comment) {
    AppRoutes.openUserProfile(
      context,
      UserProfileArgs(
        userId: comment.userId,
        userName: comment.userName,
        userAvatar: comment.userAvatar,
        userHash: comment.userHash,
      ),
    );
  }

  /// 删自己的评论：先弹确认框（破坏性操作），确认后调 controller
  /// 乐观删除；失败时 controller 会把评论放回原位并提示。
  Future<void> _confirmDelete(BookComment comment) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.commentDeleteConfirm,
      message: l10n.commentDeleteDesc,
      confirmLabel: l10n.delete,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    await _c.deleteComment(comment);
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: GradientAppBar(title: l10n.comments),
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final c = _c;
          return Column(
            children: [
              BookContextHeader(
                title: args.bookTitle,
                commentCount:
                    c.loggedIn && !c.disabled && !c.hasError && !c.isLoading
                        ? c.comments.length
                        : null,
              ),
              Expanded(child: _buildBody(c, l10n)),
              if (c.loggedIn && !c.disabled && !c.isLoading)
                CommentComposer(
                  controller: _composerController,
                  focusNode: _composerFocus,
                  hintText: l10n.writeComment,
                  replyBannerText: c.replyTo == null
                      ? null
                      : '${l10n.replyTo} ${c.replyTo!.userName}',
                  cancelTooltip: l10n.cancel,
                  sendTooltip: l10n.sendComment,
                  isPosting: c.isPosting,
                  onCancelReply: c.cancelReply,
                  onSubmit: _submit,
                ),
            ],
          );
        },
      ),
    );
  }

  /// 状态视图分发：加载 / 未登录 / 出错 / 关闭 / 空 / 列表。
  Widget _buildBody(BookCommentsController c, AppLocalizations l10n) {
    if (c.isLoading) return LoadingWidget(message: l10n.loading);
    if (!c.loggedIn) {
      return EmptyState(
        icon: Icons.login_rounded,
        title: l10n.loginToViewComments,
        action: FilledButton(
          onPressed: () => AppRoutes.openLogin(context),
          child: Text(l10n.login),
        ),
      );
    }
    if (c.hasError) {
      return EmptyState(
        icon: Icons.error_outline,
        title: l10n.error,
        message: c.errorMessage,
        action: FilledButton(
          onPressed: _reload,
          child: Text(l10n.retry),
        ),
      );
    }
    if (c.disabled) {
      return EmptyState(
        icon: Icons.comments_disabled_outlined,
        title: l10n.commentsDisabled,
      );
    }
    if (c.comments.isEmpty) {
      return EmptyState(
        icon: Icons.comment_outlined,
        title: l10n.noComments,
      );
    }
    return CommentList(
      controller: c,
      scrollController: _scrollController,
      onRefresh: _reload,
      visibleCount: c.visibleCount,
      noMoreText: l10n.noMoreComments,
      onReply: (comment) {
        _c.beginReply(comment);
        _composerFocus.requestFocus();
      },
      onAvatarTap: _openProfile,
      onLike: _c.toggleLike,
      onDelete: _confirmDelete,
      deleteTooltip: l10n.delete,
    );
  }
}
