import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/books_provider.dart';
import '../../routes/app_routes.dart';
import '../../utils/error_text.dart';
import '../../widgets/book_card.dart';
import '../../widgets/book_quick_actions_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/entrance.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';

/// 热门——官网首页"最受欢迎"栏目的承载页。`/eapi/book/most_popular`
/// 的一次快照（约 20 本；接口回 404 / success:0 / 空列表时插件自动
/// 回退 popular 排序搜索），下拉刷新重新拉取。
///
/// 与最新上架（RecentBooksScreen）同构：卡片、错误/重试入口、空态都
/// 一致。mostPopularBooksProvider 是账号维度缓存的一员（换号/换线时
/// 随 invalidateAccountScopedProviders 一起失效），这里不重复管理。
class PopularBooksScreen extends ConsumerWidget {
  const PopularBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final booksAsync = ref.watch(mostPopularBooksProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.popularBooks),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(mostPopularBooksProvider),
        child: booksAsync.when(
          loading: () => const LoadingWidget.page(),
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
                  onPressed: () => ref.invalidate(mostPopularBooksProvider),
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
            return GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
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
                    onLongPress: () =>
                        showBookQuickActionsSheet(context, book.toDisplay()),
                    onTap: () {
                      AppRoutes.openBookDetailForBook(context, book);
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
