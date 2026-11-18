import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/categories_directory_provider.dart';
import '../../routes/app_routes.dart';
import '../../screens/search/search_screen.dart';
import '../../widgets/motion/motion.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';

/// 分类目录树（方案 F1）：站点 `/categories` 页的树形浏览。顶级分类
/// 可展开看子分类（带藏书计数），点任一分类 → 站内搜索页按该分类
/// 范围浏览（复用现有 eapi 分类搜索链路）。第一组默认展开，页面打
/// 开即有可点内容。
class CategoriesDirectoryScreen extends ConsumerWidget {
  const CategoriesDirectoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final directoryAsync = ref.watch(categoriesDirectoryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.categoriesDirectory)),
      body: directoryAsync.when(
        loading: () => LoadingWidget.page(message: l10n.loading),
        error: (error, _) => EmptyState(
          icon: Icons.wifi_off_rounded,
          title: l10n.shelfSourceLoadFailed,
          message: l10n.shelfRetryHint,
          action: FilledButton.tonal(
            onPressed: () => ref.invalidate(categoriesDirectoryProvider),
            child: Text(l10n.retry),
          ),
        ),
        data: (directory) {
          if (directory.groups.isEmpty) {
            return EmptyState(
              icon: Icons.category_outlined,
              title: l10n.categoriesDirectoryEmpty,
              message: l10n.shelfTryOtherFilter,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            itemCount: directory.groups.length,
            itemBuilder: (context, index) => MotionEntrance(
              index: index,
              child: _GroupTile(
                group: directory.groups[index],
                initiallyExpanded: index == 0,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group, required this.initiallyExpanded});

  final CategoryDirectoryGroup group;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final children = group.children;
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded && children.isNotEmpty,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(
        group.parent.name,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      subtitle: children.isEmpty ? null : Text('${children.length}'),
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 28, right: 16),
          dense: true,
          leading: Icon(
            Icons.folder_open_rounded,
            size: 18,
            color: cs.primary,
          ),
          title: Text(
            group.parent.name,
            style: TextStyle(fontSize: 13, color: cs.primary),
          ),
          onTap: () => _browse(context, group.parent),
        ),
        for (final child in children)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 28, right: 16),
            dense: true,
            title: Text(child.name, style: const TextStyle(fontSize: 13)),
            trailing: child.count == null
                ? null
                : Text(
                    '${child.count}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
            onTap: () => _browse(context, child),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _browse(BuildContext context, CategoryDirectoryLink link) {
    AppRoutes.openSearchWithCategory(
      context,
      SearchScreenArgs(categoryId: link.id, categoryName: link.name),
    );
  }
}
