import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/unified_shelf_item.dart';
import '../../providers/local_collection_provider.dart';
import '../../providers/shelf_categories_provider.dart';
import '../../utils/app_snack.dart';


/// Sentinel category id meaning "no category": the shelf's
/// uncategorized filter and the picker's uncategorized row.
const kShelfUncategorizedId = '__uncategorized__';

/// The screen hooks the category flows need. Implemented by the
/// favorites screen's State: the flows run across async gaps, so every
/// context / l10n / snack touch after an await goes through here
/// instead of holding a BuildContext.
abstract class ShelfCategoryHost {
  bool get mounted;

  BuildContext get context;

  WidgetRef get ref;

  AppLocalizations l10n();

  void showMessage(String message);

  /// Called after a category was deleted; the screen drops a filter
  /// selection that pointed at it.
  void onCategoryDeleted(String categoryId);
}

/// 从 favorites_screen 抽出的分类操作流：新建、重命名、删除、把书
/// 分配进分类、管理面板。对话框与 shelfCategoriesProvider 的调用都收
/// 在这里；收藏页 State 只留选择模式与数据编排。
class ShelfCategoryActions {
  ShelfCategoryActions(this._host);

  final ShelfCategoryHost _host;

  Future<String?> createCategory() async {
    final name = await _categoryNameDialog(_host.context);
    if (name == null || !_host.mounted) return null;
    try {
      await _host.ref.read(shelfCategoriesProvider.notifier).create(name);
      final created = _host.ref.read(shelfCategoriesProvider).categories.last;
      return created.id;
    } on Object catch (_) {
      if (_host.mounted) {
        _host.showMessage(_host.l10n().shelfCategoryInvalid);
      }
      return null;
    }
  }

  Future<void> showCategoryPicker(List<UnifiedShelfItem> items) async {
    if (items.isEmpty) return;
    final l = _host.l10n();
    final categories = _host.ref.read(shelfCategoriesProvider);
    final current = items.length == 1
        ? categories.categoryFor(items.single)
        : null;
    ModalRoute<dynamic>? sheetRoute;
    final chosen = await showModalBottomSheet<String>(
      context: _host.context,
      showDragHandle: true,
      builder: (sheetContext) {
        sheetRoute = ModalRoute.of(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(l.shelfAddToCategory)),
              ListTile(
                leading: const Icon(Icons.remove_circle_outline_rounded),
                title: Text(l.shelfUncategorized),
                trailing: current == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, kShelfUncategorizedId),
              ),
              for (final category in categories.categories)
                ListTile(
                  leading: const Icon(Icons.label_outline_rounded),
                  title: Text(category.name),
                  trailing: current == category.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, category.id),
                ),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: Text(l.shelfNewCategory),
                onTap: () => Navigator.pop(sheetContext, '__new__'),
              ),
            ],
          ),
        );
      },
    );
    await sheetRoute?.completed;
    if (chosen == null || !_host.mounted) return;
    final id = chosen == '__new__' ? await createCategory() : chosen;
    if (id == null || !_host.mounted) return;
    try {
      await _host.ref
          .read(shelfCategoriesProvider.notifier)
          .assign(items, id == kShelfUncategorizedId ? null : id);
      if (_host.mounted) _host.showMessage(l.shelfCategorySaved);
    } catch (error) {
      if (_host.mounted) _host.showMessage(l.shelfCategorySaveFailed);
    }
  }

  Future<void> manageCategories() async {
    final l = _host.l10n();
    final categories = _host.ref.read(shelfCategoriesProvider).categories;
    ModalRoute<dynamic>? sheetRoute;
    final command = await showModalBottomSheet<_CategoryCommand>(
      context: _host.context,
      showDragHandle: true,
      builder: (sheetContext) {
        sheetRoute = ModalRoute.of(sheetContext);
        return SafeArea(
          child: ConstrainedBox(
            // 分类列表可能很长(审查 C3,2026-11-20):shrinkWrap 无界
            // 增长会顶破 sheet,给视口 60% 上限,超出内部滚动。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
            ),
            child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(l.shelfManageCategories)),
              for (final category in categories)
                ListTile(
                  leading: const Icon(Icons.label_outline_rounded),
                  title: Text(category.name),
                  trailing: PopupMenuButton<String>(
                    tooltip: l.more,
                    onSelected: (value) {
                      Navigator.pop(
                        sheetContext,
                        _CategoryCommand(value, category),
                      );
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(l.shelfRenameCategory),
                      ),
                      PopupMenuItem(value: 'delete', child: Text(l.delete)),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: Text(l.shelfNewCategory),
                onTap: () => Navigator.pop(
                  sheetContext,
                  const _CategoryCommand('create'),
                ),
              ),
              const PopupMenuDivider(),
              // 书架数据备份（方案 C3）：本地分类 + 本地收藏都在设备
              // 上，换机/重装就丢，导出导入是最小补偿。
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: Text(l.shelfExportData),
                onTap: () => Navigator.pop(
                  sheetContext,
                  const _CategoryCommand('export'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l.shelfImportData),
                onTap: () => Navigator.pop(
                  sheetContext,
                  const _CategoryCommand('import'),
                ),
              ),
            ],
            ),
          ),
        );
      },
    );
    await sheetRoute?.completed;
    if (!_host.mounted || command == null) return;
    if (command.action == 'create') {
      await createCategory();
    } else if (command.action == 'rename' && command.category != null) {
      await _renameCategory(command.category!);
    } else if (command.action == 'delete' && command.category != null) {
      await _deleteCategory(command.category!);
    } else if (command.action == 'export') {
      await _exportData();
    } else if (command.action == 'import') {
      await _importData();
    }
  }

  Future<void> _renameCategory(ShelfCategory category) async {
    final name = await _categoryNameDialog(
      _host.context,
      initial: category.name,
    );
    if (name == null || !_host.mounted) return;
    try {
      await _host.ref
          .read(shelfCategoriesProvider.notifier)
          .rename(category.id, name);
    } catch (error) {
      if (_host.mounted) {
        _host.showMessage(_host.l10n().shelfCategoryInvalid);
      }
    }
  }

  Future<void> _deleteCategory(ShelfCategory category) async {
    final l = _host.l10n();
    final navigator = Navigator.of(_host.context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: _host.context,
      themes: InheritedTheme.capture(
        from: _host.context,
        to: navigator.context,
      ),
      builder: (dialogContext) => AlertDialog(
        title: Text(l.shelfDeleteCategory),
        content: Text(l.shelfDeleteCategoryHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    final confirmed = await navigator.push(route);
    await route.completed;
    if (confirmed != true || !_host.mounted) return;
    try {
      await _host.ref
          .read(shelfCategoriesProvider.notifier)
          .delete(category.id);
      _host.onCategoryDeleted(category.id);
    } on Object catch (_) {
      if (_host.mounted) _host.showMessage(l.shelfCategorySaveFailed);
    }
  }

  // ── 书架数据备份（方案 C3）────────────────────────────────────

  /// 导出：本地分类 + 分配关系 + 本地收藏打包成一个 JSON 文件，走
  /// 系统分享面板交给用户保存。临时文件由分享目标接管，这里不清理。
  Future<void> _exportData() async {
    final l = _host.l10n();
    final categories = _host.ref.read(shelfCategoriesProvider);
    final collection = _host.ref.read(localCollectionProvider.notifier);
    final json = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'categories': [
        for (final category in categories.categories)
          {'id': category.id, 'name': category.name},
      ],
      'assignments': categories.assignments,
      'collection': collection.exportEntries(),
    });
    try {
      final tempDir = await Directory.systemTemp.createTemp('zlibx_shelf');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}shelf_backup_'
        '${DateTime.now().toLocal().toIso8601String().substring(0, 10)}.json',
      );
      await file.writeAsString(json, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: l.shelfExportData),
      );
      if (_host.mounted) _host.showMessage(l.shelfExportDone);
    } catch (error) {
      if (_host.mounted) _host.showMessage(l.shelfImportFailed);
    }
  }

  /// 导入：从用户挑的 JSON 文件合并进来。分类按名字去重（同名沿用
  /// 本机分类，只收新名字）；分配关系按"导入分类 id → 本机 id"映射
  /// 落键；本地收藏按 来源+md5 去重。只认 version 1。
  Future<void> _importData() async {
    final l = _host.l10n();
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (!_host.mounted) return;
    // file_picker 13.x：pickFiles 直接返回 List<PlatformFile>，字节
    // 走 readAsBytes()（旧版 withData/bytes 已删）。
    final bytes = picked.isNotEmpty ? await picked.first.readAsBytes() : null;
    if (bytes == null) return;
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException('version');
      final importedAssignments =
          (data['assignments'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const <String, String>{};
      final importedCategories =
          (data['categories'] as List<dynamic>? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();

      // 分类合并：同名沿用本机 id；新名字用导入 id（撞本机已有 id 时
      // 时间戳生成一个新 id 兜底）。
      final idMap = <String, String>{};
      final notifier = _host.ref.read(shelfCategoriesProvider.notifier);
      final existing = _host.ref.read(shelfCategoriesProvider);
      final existingNames = {
        for (final category in existing.categories)
          category.name.toLowerCase(): category.id,
      };
      for (final raw in importedCategories) {
        final importId = raw['id']?.toString();
        final name = raw['name']?.toString();
        if (importId == null || name == null || name.trim().isEmpty) continue;
        final mergedId = existingNames[name.toLowerCase()];
        if (mergedId != null) {
          idMap[importId] = mergedId;
        } else {
          try {
            await notifier.create(name);
            final created = _host.ref
                .read(shelfCategoriesProvider)
                .categories
                .last;
            idMap[importId] = created.id;
            existingNames[name.toLowerCase()] = created.id;
          } catch (_) {
            // 重名并发等极端情况：跳过这条分类，分配键随之丢弃。
          }
        }
      }

      // 分配关系：按 idMap 重映射后逐键落键（键指向的书不在本机也无妨，
      // 语义只是"哪本书属于哪个分类"）。
      final mapped = <String, String>{};
      for (final entry in importedAssignments.entries) {
        final categoryId = idMap[entry.value];
        if (categoryId != null) mapped[entry.key] = categoryId;
      }
      if (mapped.isNotEmpty) {
        await notifier.assignEntries(mapped);
      }

      final collectionEntries =
          (data['collection'] as List<dynamic>? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();
      final importedCount = await _host.ref
          .read(localCollectionProvider.notifier)
          .importEntries(collectionEntries);

      if (_host.mounted) _host.showMessage(l.shelfImportDone(mapped.length + importedCount));
    } on Object catch (_) {
      if (_host.mounted) _host.showMessage(l.shelfImportFailed);
    }
  }
}

class _CategoryCommand {
  const _CategoryCommand(this.action, [this.category]);

  final String action;
  final ShelfCategory? category;
}

/// 下载页的按键式分类弹层（方案 C1）：下载条目没有 UnifiedShelfItem，
/// 直接按 `download:<bookId>` 键写进与书架同一张 assignments 表——
/// 分类树全 app 一棵，书架建的分类在下载页直接可用。[current] 是该键
/// 现在的归属（单条目弹层显示勾选态用）。
Future<void> showKeysCategoryPicker(
  BuildContext context,
  WidgetRef ref,
  List<String> keys, {
  String? current,
}) async {
  if (keys.isEmpty) return;
  final l = AppLocalizations.of(context)!;
  final categories = ref.read(shelfCategoriesProvider);
  ModalRoute<dynamic>? sheetRoute;
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      sheetRoute = ModalRoute.of(sheetContext);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(l.shelfAddToCategory)),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline_rounded),
              title: Text(l.shelfUncategorized),
              trailing: current == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheetContext, kShelfUncategorizedId),
            ),
            for (final category in categories.categories)
              ListTile(
                leading: const Icon(Icons.label_outline_rounded),
                title: Text(category.name),
                trailing: current == category.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, category.id),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: Text(l.shelfNewCategory),
              onTap: () => Navigator.pop(sheetContext, '__new__'),
            ),
          ],
        ),
      );
    },
  );
  await sheetRoute?.completed;
  if (chosen == null || !context.mounted) return;
  var id = chosen;
  if (chosen == '__new__') {
    final name = await _categoryNameDialog(context);
    if (name == null || !context.mounted) return;
    try {
      await ref.read(shelfCategoriesProvider.notifier).create(name);
      id = ref.read(shelfCategoriesProvider).categories.last.id;
    } on Object catch (_) {
      if (context.mounted) {
        showAppSnack(context, l.shelfCategoryInvalid);
      }
      return;
    }
  }
  try {
    await ref
        .read(shelfCategoriesProvider.notifier)
        .assignKeys(keys, id == kShelfUncategorizedId ? null : id);
    if (context.mounted) showAppSnack(context, l.shelfCategorySaved);
  } catch (error) {
    if (context.mounted) showAppSnack(context, l.shelfCategorySaveFailed);
  }
}

Future<String?> _categoryNameDialog(
  BuildContext context, {
  String? initial,
}) async {
  final l = AppLocalizations.of(context)!;
  var name = initial ?? '';
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<String>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (dialogContext) => AlertDialog(
      title: Text(initial == null ? l.shelfNewCategory : l.shelfRenameCategory),
      content: TextFormField(
        initialValue: initial,
        autofocus: true,
        maxLength: 24,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: l.shelfCategoryName),
        onChanged: (value) => name = value,
        onFieldSubmitted: (value) => Navigator.pop(dialogContext, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, name),
          child: Text(l.save),
        ),
      ],
    ),
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}
