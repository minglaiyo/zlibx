import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/feed_controller.dart';
import '../../widgets/book_feed_grid.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';

/// 最新上架——官网首页"最近添加"栏目的信息流（2026-11-20 改版）。
///
/// 数据源与翻页规则都在 [RecentFeedController]：date 排序搜索分页累积。
/// `/eapi/book/recently` 端点在真实线路上只回 success=1 空壳（
/// 2026-11-20 实测 bookroom.lifestyle），插件本来就活在 date 搜索回退
/// 上——信息流直接取搜索源，省掉那次注定落空的请求。重开 app 第 1 页
/// 直出持久缓存（零转圈），见 [HomeFeedPageCache]。
///
/// 改版前是"下拉翻页替换内容"（1→2→…→9→1 循环）：信息流语义下累积
/// 追加，下拉回顶换新第 1 页。
class RecentBooksScreen extends ConsumerWidget {
  const RecentBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final feed = ref.watch(recentFeedProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.recentlyAdded),
      body: BookFeedGrid(
        feed: feed,
        onRefresh: () => ref.read(recentFeedProvider.notifier).refresh(),
        onLoadMore: () => ref.read(recentFeedProvider.notifier).loadMore(),
        emptyState: EmptyState(
          icon: Icons.fiber_new_rounded,
          title: l10n.recentlyAdded,
          message: l10n.recentlyAddedEmpty,
        ),
      ),
    );
  }
}
