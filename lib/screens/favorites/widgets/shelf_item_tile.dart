import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/unified_shelf_item.dart';
import '../../../providers/download_provider.dart';
import 'shelf_book_item.dart';


/// One shelf row that watches only its own download task. A progress
/// tick for another book rebuilds neither this tile nor the shelf
/// above it — the parent never watches the download list at all.
/// The completed-only filter replicates the old completedById map:
/// only a finished task with a file counts as downloaded, and only
/// that task is handed to the action sheet / quick-open.
///
/// 从 favorites_screen 移入（原 _ShelfItemTile）；行为不变。
class ShelfItemTile extends ConsumerWidget {
  const ShelfItemTile({
    super.key,
    required this.item,
    required this.isListView,
    required this.isSelectMode,
    required this.isSelected,
    required this.categoryName,
    required this.onTap,
    required this.onLongPress,
  });

  final UnifiedShelfItem item;
  final bool isListView;
  final bool isSelectMode;
  final bool isSelected;
  final String? categoryName;
  final VoidCallback onTap;

  /// Called with the item and its completed download task (null when
  /// the book has no finished download).
  final void Function(UnifiedShelfItem, DownloadTask?) onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only library items have a download task; the task id is the
    // book id string. Non-library items never watch a task.
    final DownloadTask? task = item.source == ShelfSource.library
        ? ref.watch(downloadTaskProvider(item.rawBookId))
        : null;
    final DownloadTask? local =
        (task?.status == DownloadStatus.completed && task?.filePath != null)
        ? task
        : null;
    if (isListView) {
      return ShelfListItem(
        item: item,
        isSelectMode: isSelectMode,
        isSelected: isSelected,
        categoryName: categoryName,
        isDownloaded: local != null,
        onTap: onTap,
        onLongPress: () => onLongPress(item, local),
      );
    }
    return ShelfGridItem(
      item: item,
      isSelectMode: isSelectMode,
      isSelected: isSelected,
      categoryName: categoryName,
      isDownloaded: local != null,
      onTap: onTap,
      onLongPress: () => onLongPress(item, local),
    );
  }
}
