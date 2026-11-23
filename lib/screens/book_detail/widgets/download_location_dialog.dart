import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// “指定下载位置”弹窗（#95）：详情页长按下载按钮弹出。用户填一个
/// `Download/zlibx` 下的子文件夹名，这本书就下到那个文件夹；留空
/// （或填的和默认一样）就用分类模式默认的位置。
///
/// 返回：null = 取消，不下载；"" = 确认，用默认位置；非空串 = 确认，
/// 用这个文件夹。
Future<String?> showDownloadLocationDialog(
  BuildContext context, {
  required String? defaultSubfolder,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController(text: defaultSubfolder ?? '');
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadCustomFolderTitle),
      content: StatefulBuilder(
        builder: (context, setState) {
          // 预览：输入为空或和默认一样 → 默认位置；否则是输入的文件夹。
          final input = controller.text.trim();
          final effective =
              input.isEmpty || input == defaultSubfolder
                  ? defaultSubfolder
                  : input;
          final preview =
              effective == null || effective.isEmpty
                  ? 'Download/zlibx/'
                  : 'Download/zlibx/$effective/';
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.downloadCustomFolderHint,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(
                preview,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            // 空、或和默认一样 → 用默认位置（""），不把默认写死成指定值。
            Navigator.pop(
              dialogContext,
              value.isEmpty || value == defaultSubfolder ? '' : value,
            );
          },
          child: Text(l10n.download),
        ),
      ],
    ),
  );
}
