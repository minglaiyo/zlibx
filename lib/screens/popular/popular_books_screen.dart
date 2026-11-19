import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/feed_controller.dart';
import '../../widgets/book_feed_grid.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';

/// 热门——官网首页"最受欢迎"栏目的信息流（2026-11-20 改版）。
///
/// 数据源与翻页规则都在 [PopularFeedController]：第 1 页是 eapi 快照
/// （[getMostPopular]，镜像上自动回退 popular 排序搜索），上滑加载的
/// 续页走 popular 排序搜索——快照端点无视 page 参数（2026-11-20 实测），
/// 续页必须用可翻页的搜索源；按 id 去重，官方快照与搜索排序间的重叠
/// 不会重复出现。重开 app 第 1 页直出持久缓存（零转圈），见
/// [HomeFeedPageCache]。
///
/// 改版前是"下拉翻页替换内容"（1→2→…→9→1 循环）：信息流语义下累积
/// 追加，下拉回顶换新第 1 页。
class PopularBooksScreen extends ConsumerWidget {
  const PopularBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final feed = ref.watch(popularFeedProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.popularBooks),
      body: BookFeedGrid(
        feed: feed,
        onRefresh: () => ref.read(popularFeedProvider.notifier).refresh(),
        onLoadMore: () => ref.read(popularFeedProvider.notifier).loadMore(),
        emptyState: EmptyState(
          icon: Icons.local_fire_department_outlined,
          title: l10n.popularBooks,
          message: l10n.popularBooksEmpty,
        ),
      ),
    );
  }
}
