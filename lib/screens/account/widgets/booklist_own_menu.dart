/// The own-list long-press menu for the booklists screen (P1-4 split
/// of booklists_screen.dart).
///
/// The "我的" cards in the cover flow have no anchorable "…" button, so a
/// long press opens this bottom sheet with the same actions as the card
/// menu (edit / color / public / favorite / share / delete). Returns
/// the picked [BooklistMenuAction], or null when dismissed; executing
/// the action stays with the screen (`_onMenuSelected`).
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../widgets/booklist_card.dart';

Future<BooklistMenuAction?> showBooklistOwnMenuSheet(
  BuildContext context,
  Booklist list,
) async {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<BooklistMenuAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              list.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                sheetContext,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.booklistEdit),
            onTap: () => Navigator.pop(sheetContext, BooklistMenuAction.edit),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l10n.booklistChangeColor),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistMenuAction.changeColor),
          ),
          ListTile(
            leading: Icon(
              list.isPrivate
                  ? Icons.lock_open_rounded
                  : Icons.lock_outline_rounded,
            ),
            title: Text(
              list.isPrivate
                  ? l10n.booklistMakePublic
                  : l10n.booklistMakePrivate,
            ),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistMenuAction.togglePublic),
          ),
          ListTile(
            leading: Icon(
              list.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
            ),
            title: Text(
              list.isFavorite
                  ? l10n.unfavoriteBooklist
                  : l10n.favoriteBooklist,
            ),
            onTap: () => Navigator.pop(
              sheetContext,
              BooklistMenuAction.toggleFavorite,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(l10n.share),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistMenuAction.share),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(l10n.delete),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistMenuAction.delete),
          ),
        ],
      ),
    ),
  );
}
