import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../routes/app_routes.dart';
import '../../services/view_history_storage.dart';
import '../../utils/date_text.dart';
import '../../widgets/book_list_tile.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';

/// 浏览历史（本地）：站内书详情页的最近打开记录，每次打开置顶
/// （记录点在 AppRoutes.openBookDetail，所有入口统一生效）。
/// 与官网的"浏览历史"对应；数据只存本机 Hive。
class ViewHistoryScreen extends StatefulWidget {
  const ViewHistoryScreen({super.key});

  @override
  State<ViewHistoryScreen> createState() => _ViewHistoryScreenState();
}

class _ViewHistoryScreenState extends State<ViewHistoryScreen> {
  late Future<List<({Book book, DateTime viewedAt})>> _entries;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    // entries() 是同步 Hive 读；包一层 Future 让 UI 走统一的
    // loading/error 分支（与下载历史页一致）。
    _entries = Future.sync(ViewHistoryStore.entries);
  }

  void _confirmClear() {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearViewHistory),
        content: Text(l10n.clearViewHistoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await ViewHistoryStore.clear();
              if (!mounted) return;
              setState(_reload);
            },
            child: Text(
              l10n.clear,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: GradientAppBar(
        title: l10n.viewHistory,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: l10n.clearViewHistory,
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: FutureBuilder<List<({Book book, DateTime viewedAt})>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              title: l10n.error,
              message: snapshot.error.toString(),
            );
          }
          final entries = snapshot.data ?? const [];
          if (entries.isEmpty) {
            return EmptyState(
              icon: Icons.manage_history,
              title: l10n.viewHistoryEmpty,
              message: l10n.viewHistoryEmptyMessage,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return BookListTile(
                book: entry.book.toDisplay(),
                showCover: true,
                extraLabel: formatViewedAt(entry.viewedAt),
                onTap: () {
                  // openBookDetail 内部会重新置顶该条（与网站一致：
                  // 重看即更新时间），返回后刷新列表顺序。
                  AppRoutes.openBookDetailForBook(
                    context,
                    entry.book,
                  ).whenComplete(() {
                    if (mounted) setState(_reload);
                  });
                },
              );
            },
          );
        },
      ),
    );
  }
}
