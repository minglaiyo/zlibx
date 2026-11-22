import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../core/book_description.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/books_provider.dart';
import '../../providers/download_provider.dart';
import 'book_detail_args.dart';
import 'widgets/anna_book_info_section.dart';
import 'widgets/book_action_bar.dart';
import 'widgets/book_hero_section.dart';
import 'widgets/book_info_section.dart';
import 'widgets/external_book_action_bar.dart';
import 'widgets/quota_fallback_action.dart';

/// 详情页当前该渲染的书本体：入参书本体 → eapi 正文，后到的覆盖
/// 先到的。
///
/// 拆成函数是为了能脱屏测这条合并规则。附加字段那条腿已于
/// 2026-11-20 从详情页整体撤下（卷/ISBN/IPFS/评分/关键词这些书页
/// HTML 装饰随之消失；关联书单改为静态入口、点进落地页才抓）——
/// eapi 的 interestScore 评分兜底保留。
@visibleForTesting
Book bookDetailPayload({
  required Book initialBook,
  required AsyncValue<Book>? details,
}) {
  // 加载中沿用入参书本体；失败（valueOrNull == null）同理。
  final baseBook = details == null || details.isLoading
      ? initialBook
      : (details.valueOrNull ?? initialBook);
  // Rating fallback: when the entry book already carries the eapi
  // interest score — the same ★ the search card shows — use it so the
  // hero badge is not empty. The quality side has no eapi equivalent.
  final needsRatingFallback =
      (baseBook.ratingInterest?.isEmpty ?? true) &&
      (initialBook.interestScore?.isNotEmpty ?? false);
  return needsRatingFallback
      ? baseBook.copyWith(ratingInterest: initialBook.interestScore)
      : baseBook;
}

class BookDetailScreen extends ConsumerWidget {
  /// Already normalized and validated by the route builder
  /// (see `buildAppRoutes` in `routes/app_routes.dart`).
  final BookDetailArgs args;

  const BookDetailScreen({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // External detail (Anna's Archive / LibGen): search + detail, and
    // download via the external resolver (Stage 3).
    if (args.isAnnasArchive || args.isLibGen) {
      return _ExternalBookDetail(displayBook: args.displayBook!);
    }
    // Z-Library (unchanged): BookDetailArgs or a raw vendor Book.
    // 兼容两种 arg：BookDetailArgs 和直接的 Book（旧调用方）。
    final initialBook = args.book!;
    final hash = initialBook.hash;
    // A literal "null" description counts as missing, so the detail
    // fetch still runs to get the real one.
    final needsDetails =
        initialBook.readOnlineUrl?.isNotEmpty != true ||
        normalizedBookDescription(initialBook.description) == null;
    final identifier = needsDetails && hash != null && hash.isNotEmpty
        ? BookIdentifier(
            initialBook.id.toString(),
            hash,
            title: initialBook.title,
            href: initialBook.href,
          )
        : null;
    final details = identifier == null
        ? null
        : ref.watch(bookDetailsProvider(identifier));
    // 关联书单入口只带书页 href——卷/ISBN/IPFS/评分/关键词/书单
    // 列表那条几百 KB 的书页 HTML 腿已按用户定稿（2026-11-20）从
    // 详情页撤下，点进关联书单落地页才开始抓（见
    // RelatedBooklistsScreen）。路由带的 href 优先；没带时等 eapi
    // 返回的再亮入口。
    final routeHref = initialBook.href;
    final relatedHref = (routeHref != null && routeHref.isNotEmpty)
        ? routeHref
        : details?.valueOrNull?.href;
    final book = bookDetailPayload(
      initialBook: initialBook,
      details: details,
    );
    // 只订阅本书的任务：其他书的下载进度变化不再触发本页重建。
    // 账号额度提醒仍在下面用 ref.listen 监听整个列表，不受影响。
    final downloadTask = ref.watch(
      downloadProvider.select((tasks) {
        for (final task in tasks) {
          if (task.id == book.id.toString()) return task;
        }
        return null;
      }),
    );

    // 本书下载因账号额度用尽失败时，先试其他来源（LibGen / Anna）；
    // 找不到才弹额度提醒。
    ref.listen<List<DownloadTask>>(downloadProvider, (prev, next) {
      final id = book.id.toString();
      bool quotaHit(List<DownloadTask>? list) =>
          list?.any((t) => t.id == id && t.quotaExceeded) ?? false;
      if (quotaHit(next) && !quotaHit(prev)) {
        unawaited(tryQuotaFallbackAndDownload(context, ref, book));
      }
    });

    final isDownloading = downloadTask?.status == DownloadStatus.downloading;
    final isCompleted = downloadTask?.status == DownloadStatus.completed;
    // Watch favorite state
    final favAsync = ref.watch(isBookFavoritedProvider(book.id.toString()));
    final isFavorited = favAsync.valueOrNull ?? false;

    return Scaffold(
      // ── Sticky Bottom Action Bar ──
      bottomNavigationBar: BookActionBar(
        book: book,
        downloadTask: downloadTask,
        isDownloading: isDownloading,
        isCompleted: isCompleted,
        unavailableReason: args.unavailableReason,
      ),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── 1. 封面与滚动导航 ──
          BookHeroSection(book: book.toDisplay(), isFavorited: isFavorited),

          if (details?.isLoading ?? false) const _DetailLoadingBar(),
          if (details?.hasError ?? false)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.detailUnavailablePreview,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        ref.invalidate(bookDetailsProvider(identifier!));
                      },
                      child: Text(AppLocalizations.of(context)!.searchRetry),
                    ),
                  ],
                ),
              ),
            ),

          // ── 2. Content Body ──
          // 关联书单入口行恒显（href 在手即可点），数据进落地页才抓。
          BookInfoSection(book: book, relatedHref: relatedHref),
        ],
      ),
    );
  }
}

/// External detail page (Anna's Archive / LibGen).
///
/// The search-result DisplayBook supplies title/author/cover for the hero;
/// the matching details provider fetches the full BookInfoData
/// (description, publisher, format). Once the info loads, the bottom bar
/// offers the external download (resolved by external_download.dart).
class _ExternalBookDetail extends ConsumerWidget {
  final DisplayBook displayBook;

  const _ExternalBookDetail({required this.displayBook});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookData = displayBook.isLibGen
        ? displayBook.asLibgenBookData!
        : displayBook.asAnnaBookData!;
    final detailsProvider = displayBook.isLibGen
        ? libgenBookDetailsProvider(bookData.link)
        : annasBookDetailsProvider(bookData.link);
    final details = ref.watch(detailsProvider);
    final info = details.valueOrNull;

    return Scaffold(
      // Download only makes sense once the info (mirror + md5) is known.
      bottomNavigationBar: info != null
          ? ExternalBookActionBar(displayBook: displayBook, info: info)
          : null,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // The favorite button is hidden for non-z站 books (the hero only
          // shows it when book.isZLibrary), so isFavorited is always false.
          BookHeroSection(book: displayBook, isFavorited: false),

          if (details.isLoading) const _DetailLoadingBar(),
          if (details.hasError)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.detailUnavailable,
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref.invalidate(detailsProvider),
                      child: Text(AppLocalizations.of(context)!.searchRetry),
                    ),
                  ],
                ),
              ),
            ),

          // Full info once loaded; the hero alone carries the page while
          // it is loading or when the detail fetch fails.
          if (info != null)
            AnnaBookInfoSection(displayBook: displayBook, info: info),
        ],
      ),
    );
  }
}

/// Indeterminate loading bar under the hero while full details load.
/// Shared by the Z-Library and the Anna / LibGen detail pages.
class _DetailLoadingBar extends StatelessWidget {
  const _DetailLoadingBar();

  @override
  Widget build(BuildContext context) =>
      const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2));
}
