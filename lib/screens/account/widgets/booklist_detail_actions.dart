import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';

/// 自己的单里书卡长按面板的两项动作（原 _OwnBookAction，P1-4
/// 拆出并公开；仅改名与文件位置）。
enum BooklistOwnBookAction { note, remove }

/// 自己的单里长按书卡:批注/移出两项（原 _showOwnBookActions 的
/// 弹层部分，P1-4 拆出；返回用户选的动作，由详情页执行对应的
/// 后续操作；文案与行为不变）。
Future<BooklistOwnBookAction?> showBooklistOwnBookActions(
  BuildContext context,
  Book book,
) async {
  final l10n = AppLocalizations.of(context)!;
  final note = book.note?.trim() ?? '';
  return showModalBottomSheet<BooklistOwnBookAction>(
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
              style: Theme.of(
                sheetContext,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_note_rounded),
            title: Text(
              note.isEmpty ? l10n.booklistAddNote : l10n.booklistEditNote,
            ),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistOwnBookAction.note),
          ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline_rounded),
            title: Text(l10n.booklistRemoveBook),
            onTap: () =>
                Navigator.pop(sheetContext, BooklistOwnBookAction.remove),
          ),
        ],
      ),
    ),
  );
}

/// 对一本书加批注/改批注的输入对话框（原 _editNote 的弹框部分，
/// P1-4 拆出；返回用户输入的批注，null 表示取消；文案与行为不变）。
Future<String?> showBooklistNoteDialog(
  BuildContext context,
  Book book,
) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController(text: book.note ?? '');
  final note = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        book.note == null || book.note!.isEmpty
            ? l10n.booklistAddNote
            : l10n.booklistEditNote,
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        minLines: 1,
        decoration: InputDecoration(labelText: l10n.booklistNote),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, controller.text.trim()),
          child: Text(l10n.save),
        ),
      ],
    ),
  );
  controller.dispose();
  return note;
}
