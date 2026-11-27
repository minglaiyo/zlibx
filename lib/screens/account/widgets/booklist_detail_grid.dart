import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../utils/cover_cache.dart';
import '../../../widgets/motion/entrance.dart';

/// 书架网格的固定委托:窄屏 3 列、700 起 4 列、1000 起 5 列;
/// 格高 = 矮封面 + 三行文字(随系统字号缩放)。[width] 传不含
/// 页面 padding 的可视宽(SliverLayoutBuilder 的 crossAxisExtent)。
/// 原 _shelfGridDelegate，P1-4 拆出并公开（仅改名与文件位置）。
SliverGridDelegate booklistShelfGridDelegate(
  BuildContext context,
  double width,
) {
  final columns = width >= 1000
      ? 5
      : width >= 700
      ? 4
      : 3;
  const spacing = 12.0;
  const rowGap = 18.0;
  final cell = (width - spacing * (columns - 1)) / columns;
  final coverH = cell / 0.78;
  final ts = MediaQuery.textScalerOf(context);
  final textH =
      ts.scale(8) + ts.scale(33) + ts.scale(3) + ts.scale(16) + ts.scale(4);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: spacing,
    mainAxisSpacing: rowGap,
    childAspectRatio: cell / (coverH + textH),
  );
}

/// 紧凑书架网格(2026-11-19 用户定稿):原 BookCard 封面高
/// (1.43 倍)+四行字,整屏显得又挤又长;这里改矮封面(0.78
/// 比例)+标题两行+作者一行,格式/年份/大小行删掉——详情页
/// 全都有,行距也拉开。点卡进书详情,长按(自己的单)出操作。
/// 原详情页 `_body` 的网格段，P1-4 拆出。
class BooklistDetailBookGrid extends StatelessWidget {
  final List<Book> books;
  final bool canEdit;
  final ValueChanged<Book> onTap;
  final ValueChanged<Book>? onLongPress;

  const BooklistDetailBookGrid({
    super.key,
    required this.books,
    required this.canEdit,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          return SliverGrid.builder(
            gridDelegate: booklistShelfGridDelegate(
              context,
              constraints.crossAxisExtent,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              return MotionEntrance(
                index: index,
                child: BooklistShelfTile(
                  book: book,
                  onTap: () => onTap(book),
                  onLongPress: canEdit && onLongPress != null
                      ? () => onLongPress!(book)
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 书单详情一格的矮封面卡:封面(0.78)+ 标题两行 + 作者一行。
/// 公开类供测试与未来复用;点卡进书详情,长按(自己的单)出操作。
/// P1-4 由详情页同文件移出，内容一字未动。
class BooklistShelfTile extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BooklistShelfTile({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primaryContainer,
            Color.lerp(cs.primaryContainer, cs.surfaceContainerHighest, .6)!,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_rounded,
          size: 26,
          color: cs.onPrimaryContainer.withValues(alpha: 0.55),
        ),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 0.78,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: (book.cover ?? '').isEmpty
                    ? placeholder
                    : CachedNetworkImage(
                        imageUrl: book.cover!,
                        fit: BoxFit.cover,
                        memCacheWidth: coverCacheWidth(240, context),
                        memCacheHeight: coverCacheHeight(308, context),
                        placeholder: (_, __) => placeholder,
                        errorWidget: (_, __, ___) => placeholder,
                      ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.textScalerOf(context).scale(8)),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              height: 1.28,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            (book.author ?? '').isEmpty ? ' ' : book.author!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
