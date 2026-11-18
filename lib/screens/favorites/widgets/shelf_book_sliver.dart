import 'package:flutter/material.dart';

import '../../../models/unified_shelf_item.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/shelf_categories_provider.dart';
import 'shelf_book_item.dart';
import 'shelf_item_tile.dart';


/// 从 favorites_screen 抽出的列表 / 网格体：可见条目按列表或网格
/// 铺开，每个条目经 [ShelfItemTile] 只监听自己的下载任务。选择态
/// 与点击 / 长按行为经参数与回调交回收藏页。
class ShelfBookSliver extends StatelessWidget {
  const ShelfBookSliver({
    super.key,
    required this.items,
    required this.categories,
    required this.categoryNameById,
    required this.isListView,
    required this.isSelectMode,
    required this.selectedBookIds,
    required this.onItemTap,
    required this.onItemLongPress,
  });

  final List<UnifiedShelfItem> items;
  final ShelfCategoriesState categories;
  final Map<String, String> categoryNameById;
  final bool isListView;
  final bool isSelectMode;
  final Set<int> selectedBookIds;
  final ValueChanged<UnifiedShelfItem> onItemTap;

  /// Called with the item and its completed download task (null when
  /// the book has no finished download).
  final void Function(UnifiedShelfItem, DownloadTask?) onItemLongPress;

  static const _gridPadding = 16.0;
  static const _gridSpacing = 14.0;

  @override
  Widget build(BuildContext context) {
    final columns = _shelfColumns(context);
    final cellWidth =
        (MediaQuery.sizeOf(context).width -
            _gridPadding * 2 -
            _gridSpacing * (columns - 1)) /
        columns;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_gridPadding, 4, _gridPadding, 12),
      sliver: isListView
          ? SliverList.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, index) => _tile(items[index]),
            )
          : SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: _gridSpacing,
                mainAxisSpacing: 16,
                mainAxisExtent:
                    cellWidth / ShelfGridItem.coverAspectRatio +
                    ShelfGridItem.captionHeight,
              ),
              itemCount: items.length,
              itemBuilder: (_, index) => _tile(items[index]),
            ),
    );
  }

  int _shelfColumns(BuildContext context) =>
      ((MediaQuery.sizeOf(context).width - _gridPadding * 2) / 115)
          .floor()
          .clamp(3, 8);

  int? _libraryId(UnifiedShelfItem item) =>
      item.source == ShelfSource.library ? int.tryParse(item.rawBookId) : null;

  String? _categoryName(UnifiedShelfItem item) {
    final id = categories.categoryFor(item);
    if (id == null) return null;
    return categoryNameById[id];
  }

  Widget _tile(UnifiedShelfItem item) {
    final id = _libraryId(item);
    return ShelfItemTile(
      item: item,
      isListView: isListView,
      isSelectMode: isSelectMode,
      isSelected: id != null && selectedBookIds.contains(id),
      categoryName: _categoryName(item),
      onTap: () => onItemTap(item),
      onLongPress: (it, local) => onItemLongPress(it, local),
    );
  }
}
