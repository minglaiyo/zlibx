import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/history_cover_notifier.dart';
import '../../../providers/saved_books_notifier.dart';
import '../../../utils/app_snack.dart';
import '../../book_detail/widgets/add_to_booklist_dialog.dart';

/// 搜索结果长按封面弹出的快捷操作面板：收藏到书架 / 加入书单
///（用户批 2026-11-14 功能 2）。z-lib 搜索结果的 BookCard /
/// BookListTile 传 onLongPress 进来；外部源（文章/全文命中）不走这。
///
/// 面板自己用 [ProviderScope.containerOf] 拿 provider（SearchResultsView
/// 是无 ref 的 StatelessWidget，不必为它引入 Consumer）：tile 先 pop
/// 再执行动作，动作期间的 snack 用外层 [context]（带 mounted 复查）。
Future<void> showBookQuickActionsSheet(
  BuildContext context,
  DisplayBook book,
) async {
  final l10n = AppLocalizations.of(context)!;
  final action = await showModalBottomSheet<_QuickAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border_rounded),
            title: Text(l10n.like),
            onTap: () => Navigator.pop(sheetContext, _QuickAction.favorite),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_rounded),
            title: Text(l10n.addToBooklist),
            onTap: () => Navigator.pop(sheetContext, _QuickAction.booklist),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  await _runQuickAction(context, action, book);
}

Future<void> _runQuickAction(
  BuildContext context,
  _QuickAction? action,
  DisplayBook book,
) async {
  if (action == null || !context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final container = ProviderScope.containerOf(context, listen: false);

  switch (action) {
    case _QuickAction.favorite:
      final success = await container
          .read(savedBooksProvider.notifier)
          .saveBook(book.id, book: book.asZLibBook);
      if (!context.mounted) return;
      if (success) {
        // 与详情页心形按钮同一套缓存失效：本命中的收藏态保持一致。
        container.invalidate(
          isBookFavoritedProvider(book.id),
        );
        showAppSnack(context, l10n.addedToFavorites);
      } else {
        showAppSnack(context, l10n.favoriteFailed);
      }
    case _QuickAction.booklist:
      final bookId = int.tryParse(book.id);
      if (bookId == null) {
        showAppSnack(context, l10n.errorGeneric);
        return;
      }
      final added = await showAddToBooklistDialog(context, bookId);
      if (!context.mounted) return;
      if (added) {
        showAppSnack(context, l10n.addToBooklistSuccess);
      }
  }
}

enum _QuickAction { favorite, booklist }
