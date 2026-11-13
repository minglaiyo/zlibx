import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../utils/cover_cache.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/cover_placeholder.dart';

/// 一条用户评论背后的书。“我的评论”与用户主页的评论接口都只给
/// bookId + 书名：跳书籍详情要用的 eapi hash 和书名行要显示的
/// 封面，都要靠标题搜索反查（见 [resolveCommentBookRef]）——搜索
/// 结果里同 id 的那条 [Book] 同时带着两者，一次请求两用。
class CommentBookRef {
  /// eapi hash；空串 = 尚未解析或没搜到。
  final String hash;

  /// 封面 URL；空串 = 尚未解析、没搜到或该书无封面。
  final String cover;

  const CommentBookRef({required this.hash, required this.cover});

  bool get hasHash => hash.isNotEmpty;
}

/// 标题搜索反查书目信息：取搜索结果中同 id 那条的 hash 与封面。
/// 没命中或搜索失败返回 null（调用方自行按 bookId 缓存去重，
/// 同一本书全 app 会话内只搜一次由各页面的缓存保证）。
Future<CommentBookRef?> resolveCommentBookRef(
  ZLibraryApi api,
  int bookId,
  String title,
) async {
  final res = await api.search(message: title, limit: 20);
  if (!res.success || res.data == null) return null;
  for (final book in res.data!) {
    if (book.id == bookId) {
      return CommentBookRef(
        hash: book.hash ?? '',
        cover: book.cover ?? '',
      );
    }
  }
  return null;
}

/// 评论卡片的书名行（“我的评论”页与用户主页评论列表共用）：
/// 封面缩略图 + 书名 + 尾部箭头，点击进书籍详情。hash 解析中
/// 行尾转圈并禁止再点；封面未解析到（或加载失败）显示静态占位图，
/// 与全 app 的封面占位同一套视觉（[CoverPlaceholder]）。
class CommentBookTile extends StatelessWidget {
  final String title;

  /// 封面 URL；null / 空串 → 占位图。
  final String? coverUrl;

  /// hash 解析中：行尾转圈、禁点。
  final bool busy;
  final VoidCallback? onTap;

  const CommentBookTile({
    super.key,
    required this.title,
    this.coverUrl,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 34,
              height: 48,
              child: (coverUrl ?? '').isEmpty
                  ? const CoverPlaceholder.static()
                  : CachedNetworkImage(
                      imageUrl: coverUrl!,
                      fit: BoxFit.cover,
                      // 缩略图按显示尺寸解码，避免整图占内存。
                      memCacheWidth: coverCacheWidth(34, context),
                      memCacheHeight: coverCacheHeight(48, context),
                      placeholder: (context, url) =>
                          const CoverPlaceholder.static(),
                      errorWidget: (context, url, error) =>
                          const CoverPlaceholder.static(),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: tt.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(10),
              child: LoadingWidget.inline(size: 16),
            )
          else
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: cs.outline,
            ),
        ],
      ),
    );
  }
}
