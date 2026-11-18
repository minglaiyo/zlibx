import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Per-book comments 的状态与业务逻辑，从 widget 里抽离出来，
/// screen 只负责接 provider 和画 UI。
///
/// 网络行为与原实现完全一致（抓包于 2026-11-06 的 papi/ 接口）：
/// 打开时按 `limit=500` 拉全量（去重、上限 1000 条），用
/// [orderCommentsNewestFirst] 排成最新线程在前，之后滚动只做本地分页；
/// 点赞乐观更新、失败回滚。
///
/// [api] 为 `zlibraryApiProvider` 提供的 `ZLibraryApi` 单例。
class BookCommentsController extends ChangeNotifier {
  BookCommentsController({
    required this.bookId,
    required this.api,
    required this.commentFailed,
    required this.likeFailed,
    required this.commentDeleteFailed,
    this.onNotice,
  });

  final int bookId;
  final ZLibraryApi api;

  /// 失败提示文案（screen 传入已解析的本地化字符串）。
  final String commentFailed;
  final String likeFailed;
  final String commentDeleteFailed;

  /// 瞬态提示（screen 传入 SnackBar 展示）。
  final ValueChanged<String>? onNotice;

  static const int pageSize = 50;
  static const int fetchLimit = 500;
  static const int maxFetchComments = 1000;
  static const int maxFetchPages = 4;

  final List<BookComment> comments = [];
  final Set<int> likingIds = {};
  final Set<int> deletingIds = {};
  Map<int, int> replyCounts = {};

  int visibleCount = pageSize;
  bool hasMore = true;
  bool isLoading = true;
  bool hasError = false;
  String errorMessage = '';
  bool disabled = false;
  bool loggedIn = true;
  BookComment? replyTo;
  bool isPosting = false;

  bool _disposed = false;

  void _notice(String message) => onNotice?.call(message);

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ---------------------------------------------------------------- 加载

  Future<void> loadFirst({required bool signedIn}) async {
    if (!signedIn) {
      loggedIn = false;
      isLoading = false;
      _emit();
      return;
    }
    loggedIn = true;
    isLoading = true;
    hasError = false;
    comments.clear();
    replyCounts = {};
    visibleCount = pageSize;
    hasMore = true;
    disabled = false;
    _emit();
    await _loadAll();
    if (_disposed) return;
    isLoading = false;
    _emit();
  }

  /// 拉全量（最旧在前），本地排成最新线程在前；中途失败就展示已拿到的部分。
  Future<void> _loadAll() async {
    final collected = <BookComment>[];
    final seenIds = <int>{};
    var disabled = false;
    var error = '';
    for (
      var page = 0;
      page < maxFetchPages && collected.length < maxFetchComments;
      page++
    ) {
      try {
        final response = await api.getBookComments(
          bookId.toString(),
          page: page,
          limit: fetchLimit,
        );
        if (_disposed) return;
        if (!response.success || response.data == null) {
          if (page == 0) {
            error = response.error ?? 'Failed to load comments';
          }
          break;
        }
        final data = response.data!;
        if (data.disabled) {
          disabled = true;
          break;
        }
        // 去重：后续页若全是已见过的评论，说明分页重叠，直接停。
        var newCount = 0;
        for (final comment in data.comments) {
          if (seenIds.add(comment.id)) {
            collected.add(comment);
            newCount++;
          }
        }
        if (newCount == 0) break;
        if (data.comments.length < fetchLimit) break;
      } catch (e) {
        if (_disposed) return;
        if (page == 0) error = e.toString();
        break;
      }
    }
    if (_disposed) return;
    if (disabled) {
      this.disabled = true;
      hasMore = false;
    } else if (error.isNotEmpty && collected.isEmpty) {
      hasError = true;
      errorMessage = error;
    } else {
      comments
        ..clear()
        ..addAll(orderCommentsNewestFirst(collected));
      replyCounts = {};
      for (final comment in comments) {
        final parentId = comment.parentId;
        if (parentId != null) {
          replyCounts[parentId] = (replyCounts[parentId] ?? 0) + 1;
        }
      }
      visibleCount = pageSize;
      hasMore = comments.length > visibleCount;
    }
    _emit();
  }

  /// 滚动接近底部时 revealing 更多已加载内容。
  void showMore() {
    if (!hasMore || isLoading || hasError) return;
    visibleCount += pageSize;
    if (visibleCount >= comments.length) {
      visibleCount = comments.length;
      hasMore = false;
    }
    _emit();
  }

  // ---------------------------------------------------------------- 回复

  void beginReply(BookComment comment) {
    replyTo = comment;
    _emit();
  }

  void cancelReply() {
    replyTo = null;
    _emit();
  }

  // ---------------------------------------------------------------- 发帖

  /// 返回 true 表示已发布，screen 据此清空输入框。
  Future<bool> submit(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty || isPosting) return false;
    final replyTarget = replyTo;
    isPosting = true;
    _emit();
    try {
      final response = await api.postBookComment(
        bookId.toString(),
        text: text,
        parentId: replyTarget?.id.toString(),
      );
      if (_disposed) return false;
      if (response.success && response.data != null) {
        final posted = response.data!;
        if (replyTarget == null) {
          // 新顶层评论排在站点列表最前
          comments.insert(0, posted);
        } else {
          final parentIndex = comments.indexWhere(
            (c) => c.id == replyTarget.id,
          );
          if (parentIndex >= 0) {
            comments.insert(parentIndex + 1, posted);
            replyCounts[replyTarget.id] =
                (replyCounts[replyTarget.id] ?? 0) + 1;
          } else {
            comments.insert(0, posted);
          }
        }
        if (comments.length > visibleCount) hasMore = true;
        replyTo = null;
        isPosting = false;
        _emit();
        return true;
      }
      isPosting = false;
      _emit();
      _notice('$commentFailed: ${response.error ?? ''}'.trim());
      return false;
    } catch (e) {
      if (_disposed) return false;
      isPosting = false;
      _emit();
      _notice('$commentFailed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------- 点赞

  Future<void> toggleLike(BookComment comment) async {
    if (likingIds.contains(comment.id)) return;
    final target = !comment.isLiked;
    final index = comments.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    // 乐观切换；服务端返回的数字优先
    likingIds.add(comment.id);
    comments[index] = comment.copyWith(
      isLiked: target,
      likeCount: (comment.likeCount + (target ? 1 : -1)).clamp(0, 1 << 30),
    );
    _emit();
    try {
      final response = await api.likeBookComment(comment.id, like: target);
      if (_disposed) return;
      likingIds.remove(comment.id);
      final i = comments.indexWhere((c) => c.id == comment.id);
      if (i >= 0) {
        if (response.success && response.data != null) {
          final result = response.data!;
          comments[i] = comments[i].copyWith(
            isLiked: result.liked,
            likeCount: result.count,
          );
        } else {
          comments[i] = comment; // 服务端没接受，回滚
          _notice(likeFailed);
        }
      }
    } catch (_) {
      if (_disposed) return;
      likingIds.remove(comment.id);
      final i = comments.indexWhere((c) => c.id == comment.id);
      if (i >= 0) comments[i] = comment;
      _notice(likeFailed);
    }
    _emit();
  }

  // ---------------------------------------------------------------- 删除

  /// 删除自己的评论。乐观移除，失败时放回原位并提示；被删评论若是
  /// 回复，父评论的回复数同步减一（失败时恢复）。
  Future<void> deleteComment(BookComment comment) async {
    if (deletingIds.contains(comment.id)) return;
    final index = comments.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    deletingIds.add(comment.id);
    final removed = comments.removeAt(index);
    final parentId = removed.parentId;
    final hadReplyCount = parentId != null && (replyCounts[parentId] ?? 0) > 0;
    if (hadReplyCount) replyCounts[parentId] = replyCounts[parentId]! - 1;
    _emit();
    try {
      final response = await api.deleteBookComment(comment.id);
      if (_disposed) return;
      deletingIds.remove(comment.id);
      if (!response.success) {
        comments.insert(index.clamp(0, comments.length), removed);
        if (hadReplyCount) {
          replyCounts[parentId] = (replyCounts[parentId] ?? 0) + 1;
        }
        _notice(commentDeleteFailed);
      }
    } catch (_) {
      if (_disposed) return;
      deletingIds.remove(comment.id);
      comments.insert(index.clamp(0, comments.length), removed);
      if (hadReplyCount) {
        replyCounts[parentId] = (replyCounts[parentId] ?? 0) + 1;
      }
      _notice(commentDeleteFailed);
    }
    _emit();
  }
}
