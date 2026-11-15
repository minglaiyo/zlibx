import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/books_provider.dart';
import '../../providers/settings_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_layout.dart';
import '../../utils/error_text.dart';
import '../../widgets/book_card.dart';
import '../../widgets/book_quick_actions_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/entrance.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';

/// 热门——官网首页"最受欢迎"栏目的承载页。`/eapi/book/most_popular`
/// 的一次快照（约 20 本；接口回 404 / success:0 / 空列表时插件自动
/// 回退 popular 排序搜索），下拉刷新翻到下一页，拿到不同批次。
///
/// 刷新走下拉一条路径（[_PopularBooksScreenState._refresh] 里的翻页），
/// AsyncValue 的加载 / 错误 / 空 / 数据四档都能触发下拉——手势靠子组件
/// 越界滚动，所以四档各给一个可滚的外壳。右上角没有显式刷新按钮，下拉时
/// RefreshIndicator 的圆弧指示器先给手势反馈（悬挂在顶部），松手后再由
/// 加载档的星型 blob 表示请求还在跑。
///
/// 翻页（1→2→3→1 循环）：热门与最新两页的接口回退到 search 时，之前
/// 永远打第 1 页 limit 20，刷新后内容完全不变，用户看到的就是"加载
/// 没用还是那几本"。改成按页码分页（[mostPopularBooksProvider] 是
/// family），刷新时翻页 + invalidate，每轮拿到不同批次。
///
/// 与最新上架（RecentBooksScreen）同构：卡片、错误/重试入口、空态都
/// 一致。mostPopularBooksProvider 是账号维度缓存的一员（换号/换线时
/// 随 invalidateAccountScopedProviders 一起失效），这里不重复管理。
class PopularBooksScreen extends ConsumerStatefulWidget {
  const PopularBooksScreen({super.key});

  @override
  ConsumerState<PopularBooksScreen> createState() =>
      _PopularBooksScreenState();
}

class _PopularBooksScreenState extends ConsumerState<PopularBooksScreen> {
  /// 翻页上限：热门回退搜索翻 1→2→…→9→1，每页约 20 本，九页让多轮
  /// 刷新都能看到不同批次。注意：popular 排序越往后越冷门，且被墙
  /// 线路上每页请求都可能落到无头 WebView solver，深页会变慢。
  static const int _maxPage = 9;

  int _page = 1;

  /// 下拉与错误档的重试按钮走同一条路径：翻到下一页，invalidate 这一页
  /// 再等这一轮请求真的跑完。之前写的是 `() async => ref.invalidate(...)`
  ///——invalidate 只把 provider 标脏就返回，指示器立刻收起，慢线 / 被墙
  /// 时看着就像"拉了没反应"。
  Future<void> _refresh() async {
    final next = _page >= _maxPage ? 1 : _page + 1;
    setState(() => _page = next);
    ref.invalidate(mostPopularBooksProvider(_page));
    try {
      await ref.read(mostPopularBooksProvider(_page).future);
    } on Object catch (_) {
      // 失败不往外抛：AsyncError 会让下面走错误分支，那里有重试按钮。
      // on Object 而不是 Exception——接口层是 throw StateError(...)，
      // StateError 属于 Error。
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final booksAsync = ref.watch(mostPopularBooksProvider(_page));
    // 外观设置里的"书籍网格自适应列数"（默认关）：关掉时本页维持固定
    // 两列、左右 16 的原样；打开时列数、留白、格高都和首页同一套规则。
    final adaptive = ref.watch(adaptiveGridProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.popularBooks),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: booksAsync.when(
          // 加载档也必须能下拉：RefreshIndicator 的手势靠子组件越界滚动
          // 触发，而 LoadingWidget.page() 是个 Center(Column)，滚不动。接口
          // 慢或这条线被墙时页面就停在这一档，既不能下拉也没有重试按钮，
          // 整页没有任何刷新入口（首页三档状态用 _StatePane 包着，同一个
          // 道理，见 home_book_grid.dart）。
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.2),
              const LoadingWidget.page(),
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
                    icon: Icons.local_fire_department_outlined,
                    title: l10n.popularBooks,
                    message: l10n.popularBooksEmpty,
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
                  // 自适应档：列数 / 留白 / 间距 / 格高全部走 BookCard 那一
                  // 个工厂，和首页同一套规则（手机上就是 3 列）。关掉时保
                  // 持本页原来的固定委托：两列、0.65、间距 12。
                  gridDelegate: adaptive
                          ? BookCard.adaptiveGridDelegate(context, width)
                          : const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: 0.65,
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
                        // 长按封面：收藏 / 加入书单快捷面板（与最新上架一致）。
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
