import 'package:flutter/material.dart';

import '../../../theme/app_layout.dart';
import '../../../widgets/cover_placeholder.dart';

/// 从 search_screen 抽出的零状态段：搜索加载骨架网格。
class SearchSkeletonGrid extends StatelessWidget {
  const SearchSkeletonGrid({
    super.key,
    this.adaptiveGridColumns = false,
  });

  /// 与 SearchResultsView 的书本网格同一开关、同一分支：加载完成后
  /// 列数不能跳一下。两个文件的 delegate 参数要改就一起改。
  final bool adaptiveGridColumns;

  @override
  Widget build(BuildContext context) {
    // 列数问 AppLayout，问的是网格盒子自身的宽度（LayoutBuilder 而不是
    // MediaQuery：窗口宽和这块的宽在两栏 / 桌面自由窗口下不是一回事，
    // 而且只有前者能在 widget test 里按渲染尺寸验）。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = adaptiveGridColumns
            ? AppLayout.pageGutter(width)
            : 16.0;
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 16),
          gridDelegate: adaptiveGridColumns
              ? SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: AppLayout.fullCardGridColumns(width),
                  childAspectRatio: 0.60,
                  // 12 = AppLayout.listGridSpacing：自适应公式假设的就是
                  // 这个间距，改动其中一边会让卡片宽度偏离 168 的下限。
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                )
              : const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  childAspectRatio: 0.60,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
          itemCount: 8,
          itemBuilder: (_, __) {
            // 骨架用已有的 CoverPlaceholder.shimmer（1500ms 渐变扫过），
            // 不再用静态灰块；布局、数量、尺寸与原来一致。
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CoverPlaceholder.shimmer(),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            height: 12,
                            width: double.infinity,
                            child: CoverPlaceholder.shimmer(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: SizedBox(
                            height: 10,
                            width: 80,
                            child: CoverPlaceholder.shimmer(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
