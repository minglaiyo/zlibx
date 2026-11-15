import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/books_provider.dart';
import '../../providers/settings_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_layout.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/entrance.dart';
import '../../widgets/book_quick_actions_sheet.dart';
import '../../utils/error_text.dart';
import '../../widgets/gradient_app_bar.dart';

/// 最新上架——官网首页"最近添加"栏目的承载页。`/eapi/book/recently`
/// 的一次快照（约 20 本；该接口只回 success=1 不带书单，404 或
/// 空列表时插件自动回退到 date 排序搜索），下拉刷新翻到下一页，拿到
/// 不同批次。
///
/// 刷新与热门页同构：下拉走 [_RecentBooksScreenState._refresh] 里的翻页
/// 路径，加载 / 错误 / 空 / 数据四档都能下拉（每档都给一个可越界滚动的
/// 外壳）。右上角没有显式刷新按钮，下拉时 RefreshIndicator 的圆弧指示器
/// 先给手势反馈；加载档不再放任何指示器（星型 blob 已去掉），松手后页面
/// 是空白的，等数据到了再出内容；错误档仍留着重试按钮兜底。
///
/// 翻页（1→2→3→1 循环）：回退到 date 排序搜索时之前永远打第 1 页
/// limit 20，刷新后内容不变。改成按页码分页（[recentBooksProvider] 是
/// family），刷新翻页 + invalidate，每轮拿到不同批次。
///
/// recentBooksProvider 是账号维度缓存的一员（换号/换线时随
/// invalidateAccountScopedProviders 一起失效），这里不重复管理。
class RecentBooksScreen extends ConsumerStatefulWidget {
  const RecentBooksScreen({super.key});

  @override
  ConsumerState<RecentBooksScreen> createState() => _RecentBooksScreenState();
}

class _RecentBooksScreenState extends ConsumerState<RecentBooksScreen> {
  /// 翻页上限：最新回退搜索翻 1→2→…→9→1，理由同热门页。
  static const int _maxPage = 9;

  int _page = 1;

  /// 与热门页同构：下拉和错误档的重试按钮都走这条路径，翻到下一页，
  /// invalidate 之后等这一轮请求跑完，指示器的时长就是网络时长。
  Future<void> _refresh() async {
    final next = _page >= _maxPage ? 1 : _page + 1;
    setState(() => _page = next);
    ref.invalidate(recentBooksProvider(_page));
    try {
      await ref.read(recentBooksProvider(_page).future);
    } on Object catch (_) {
      // 失败不往外抛：AsyncError 会让下面走错误分支，那里有重试按钮。
      // on Object 而不是 Exception——接口层是 throw StateError(...)，
      // StateError 属于 Error。
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final booksAsync = ref.watch(recentBooksProvider(_page));
    // 外观设置里的"书籍网格自适应列数"（默认关）：关掉时本页维持固定
    // 两列、左右 16 的原样；打开时列数与留白都按窗口宽度算。
    final adaptive = ref.watch(adaptiveGridProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.recentlyAdded),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: booksAsync.when(
          // 加载档也必须能下拉：RefreshIndicator 的手势靠子组件越界滚动
          // 触发，所以这里给一个可滚的 ListView 外壳（星型 blob 已去掉，
          // 里面只有一段空白）。接口慢或这条线被墙时页面就停在这一档，
          // 只能下拉刷新，等数据到了再出内容（首页三档状态用 _StatePane
          // 包着）。
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.2),
            ],
          ),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.2),
              EmptyState(
                icon: Icons.error_outline,
                title: l10n.error,
                message: friendlyErrorText(error, l10n),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retry),
                ),
              ),
            ],
          ),
          data: (books) {
            if (books.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.2),
                  EmptyState(
                    icon: Icons.fiber_new_rounded,
                    title: l10n.recentlyAdded,
                    message: l10n.recentlyAddedEmpty,
                  ),
                ],
              );
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final gutter = adaptive
                    ? AppLayout.pageGutter(width)
                    : 16.0;
                return GridView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 24),
                  // 自适应档：列数 / 留白 / 间距走 BookCard 那一个工厂，
                  // 和首页同一套规则（手机上就是 3 列），格高只给封面
                  // （coverOnly），信息区不再占高度。关掉时保持本页原来
                  // 的固定委托：两列、间距 12，比例换成纯封面的 0.7。
                  gridDelegate: adaptive
                          ? BookCard.adaptiveGridDelegate(
                              context,
                              width,
                              coverOnly: true,
                            )
                          : const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: BookCard.coverAspectRatio,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return EntranceSlideFade(
                      index: index,
                      child: BookCard(
                        book: book.toDisplay(),
                        // 与首页推荐同款观感：只有封面和封面上的评分，
                        // 书名 / 作者 / 格式 / 大小那几行不再占格子。
                        coverOnly: true,
                        // 长按封面：收藏 / 加入书单快捷面板（功能 2 推广）。
                        onLongPress: () => showBookQuickActionsSheet(
                          context,
                          book.toDisplay(),
                        ),
                        onTap: () {
                          AppRoutes.openBookDetailForBook(context, book);
                        },
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
