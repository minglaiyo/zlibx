import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/book_details_provider.dart';
import '../../providers/booklist_detail_provider.dart' show BooklistDetailArgs;
import '../../routes/app_routes.dart';
import '../../widgets/booklist_card.dart' show BooklistSkeletonList;
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/booklist_tile.dart';

/// 路由参数：书的详情页路径（附加字段抓取键）。数据不再由详情页
/// 预取带来——用户定稿 2026-11-20：详情页只显示静态入口，点进来
/// 才开始拉书页 HTML 并解析关联书单。
class RelatedBooklistsArgs {
  final String href;

  const RelatedBooklistsArgs({required this.href});
}

/// 详情页"关联书单"入口的落地页（2026-11-19 整体重设计）：
/// 双列上下滑动瀑布流——每格一张封面大卡（遮罩白字 + 册数），
/// 交错错峰淡入。点击进书单详情，长按弹收藏/分享面板。
///
/// 数据在进入本页时才抓（[bookDetailExtrasProvider] 的同一条缓存/
/// 去重管线：7 天持久缓存、在途共享、超时后台续跑回写），布局与
/// 书单主页共用 [BooklistMasonryGrid]。
class RelatedBooklistsScreen extends ConsumerWidget {
  final String href;

  const RelatedBooklistsScreen({super.key, required this.href});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final extrasAsync = ref.watch(bookDetailExtrasProvider(href));
    final lists = bookDetailRelatedBooklists(extrasAsync.valueOrNull);

    final Widget body;
    if (lists.isNotEmpty) {
      body = SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 14),
        child: BooklistMasonryGrid(
          lists: lists,
          // 用户定稿:本页不在封面角上放爱心——收藏走长按面板。
          showFavoriteBadge: false,
          onOpen: (list) => AppRoutes.openBooklistDetail(
            context,
            BooklistDetailArgs(booklist: list),
          ),
          onLongPress: (list) => showBooklistQuickActionsSheet(context, list),
        ),
      );
    } else if (extrasAsync.isLoading) {
      // 骨架是竖排 Column,套滚动防小屏溢出(与书单主页同款守卫)。
      body = SingleChildScrollView(
        child: BooklistSkeletonList(count: 4),
      );
    } else {
      // 有值但空表 = 书页上确实没有关联书单；value 为 null = 抓取
      // 失败/超时（连过期缓存都没有）。各给一句实话，失败态留重试。
      final failed = extrasAsync.valueOrNull == null;
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              failed ? l10n.relatedBooklistsFailed : l10n.relatedBooklistsEmpty,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (failed) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => ref.invalidate(bookDetailExtrasProvider(href)),
                child: Text(l10n.searchRetry),
              ),
            ],
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.relatedBooklists)),
      body: SafeArea(child: body),
    );
  }
}
