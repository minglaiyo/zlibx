import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/books_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';

/// 最新上架——官网首页"最近添加"栏目的承载页。`/eapi/book/recently`
/// 的一次快照（约 20 本；该接口只回 success=1 不带书单，404 或
/// 空列表时插件自动回退到 date 排序搜索），下拉刷新重新拉取。
/// 卡片与首页推荐一致（BookCard）。
///
/// recentBooksProvider 是账号维度缓存的一员（换号/换线时随
/// invalidateAccountScopedProviders 一起失效），这里不重复管理。
class RecentBooksScreen extends ConsumerWidget {
  const RecentBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final booksAsync = ref.watch(recentBooksProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.recentlyAdded),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(recentBooksProvider),
        child: booksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.2),
              EmptyState(
                icon: Icons.error_outline,
                title: l10n.error,
                message: error.toString(),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: () => ref.invalidate(recentBooksProvider),
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
                return BookCard(
                  book: book.toDisplay(),
                  onTap: () {
                    AppRoutes.openBookDetailForBook(context, book);
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
