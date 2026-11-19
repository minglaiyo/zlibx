import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart' show BooklistDetailArgs;
import '../../routes/app_routes.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/booklist_tile.dart';

/// 详情页"关联书单"入口的落地页(2026-11-19 整体重设计):
/// 双列上下滑动瀑布流——每格一张封面大卡(遮罩白字 + 册数),
/// 交错错峰淡入。点击进书单详情,长按弹收藏/分享面板。
///
/// 数据从路由参数直接传入(详情页附加字段腿拉回并缓存好的小列表,
/// 通常几项),不再为渲染一页重新请求。布局与书单主页共用
/// [BooklistMasonryGrid]。
class RelatedBooklistsScreen extends StatelessWidget {
  final List<Booklist> booklists;

  const RelatedBooklistsScreen({super.key, required this.booklists});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.relatedBooklists)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 14),
          child: BooklistMasonryGrid(
            lists: booklists,
            // 用户定稿:本页不在封面角上放爱心——收藏走长按面板。
            showFavoriteBadge: false,
            onOpen: (list) => AppRoutes.openBooklistDetail(
              context,
              BooklistDetailArgs(booklist: list),
            ),
            onLongPress: (list) => showBooklistQuickActionsSheet(context, list),
          ),
        ),
      ),
    );
  }
}
