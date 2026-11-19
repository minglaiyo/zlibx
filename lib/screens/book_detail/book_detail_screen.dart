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
import 'widgets/download_quota_dialog.dart';
import 'widgets/external_book_action_bar.dart';

/// 详情页当前该渲染的书本体：入参书本体 → eapi 正文 → 已到达的
/// 附加字段，后到的覆盖先到的（[applyBookDetailExtras] 的空值语义是
/// “保留原值”，所以附加字段只补行、不抹行）。
///
/// 拆成函数是为了能脱屏测这条合并规则：2026-11-15 提速把附加字段挪
/// 成了独立的一条腿，"正文不等它、它到了再并进来" 就是这次改动的全
/// 部意义，值得单独钉住。
@visibleForTesting
Book bookDetailPayload({
  required Book initialBook,
  required AsyncValue<Book>? details,
  required Map<String, dynamic>? extras,
}) {
  // 加载中沿用入参书本体；失败（valueOrNull == null）同理。
  final baseBook = details == null || details.isLoading
      ? initialBook
      : (details.valueOrNull ?? initialBook);
  final withExtras = extras == null
      ? baseBook
      : applyBookDetailExtras(baseBook, extras);
  // Rating fallback: when the detail-page HTML fetch failed (slow
  // link / walled page) the provider book carries no rating, but the
  // entry book already has the eapi interest score — the same ★ the
  // search card shows. Use it for the interest side so the tag is
  // not empty; the HTML value wins whenever it exists. The quality
  // side has no eapi equivalent and stays HTML-only.
  final needsRatingFallback =
      (withExtras.ratingInterest?.isEmpty ?? true) &&
      (initialBook.interestScore?.isNotEmpty ?? false);
  return needsRatingFallback
      ? withExtras.copyWith(ratingInterest: initialBook.interestScore)
      : withExtras;
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
    // 附加字段（卷/ISBN/IPFS/评分/关键词/关联书单）另起一条独立的
    // 腿：正文只等 eapi，这几行字到了再并进来看（见
    // bookDetailExtrasProvider）。路由带的 href 优先——它第一帧就
    // 有，两条腿因此并行；路由没带时用 eapi 返回的，那一轮才开跑。
    //
    // 这条腿不许被 needsDetails 门控（2026-11-15 拆分时误耦合，
    // device-verified 2026-11-19）：eapi 搜索项自带简介与在线阅读
    // 链接，搜索直达的书 needsDetails=false、identifier=null，若
    // 腿跟着 identifier 一起短路，ISBN/评分/关键词/关联书单对最常
    // 见的入口永远不显示。只要有任何一个 href 就跑——抓取本身
    // best-effort，失败只是少几行装饰，正文不受影响。
    final routeHref = initialBook.href;
    final extrasHref = (routeHref != null && routeHref.isNotEmpty)
        ? routeHref
        : details?.valueOrNull?.href;
    final extrasAsync =
        extrasHref == null || extrasHref.isEmpty
        ? null
        : ref.watch(bookDetailExtrasProvider(extrasHref));
    final book = bookDetailPayload(
      initialBook: initialBook,
      details: details,
      extras: extrasAsync?.valueOrNull,
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

    // 本书下载因账号额度用尽失败时弹一次提醒
    ref.listen<List<DownloadTask>>(downloadProvider, (prev, next) {
      final id = book.id.toString();
      bool quotaHit(List<DownloadTask>? list) =>
          list?.any((t) => t.id == id && t.quotaExceeded) ?? false;
      if (quotaHit(next) && !quotaHit(prev)) showDownloadQuotaDialog(context);
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
                        // 附加字段那条腿独立失败（超时/墙），重试也要
                        // 各试一次——正文成功不代表它成功。
                        final href = extrasHref;
                        if (href != null && href.isNotEmpty) {
                          ref.invalidate(bookDetailExtrasProvider(href));
                        }
                      },
                      child: Text(AppLocalizations.of(context)!.searchRetry),
                    ),
                  ],
                ),
              ),
            ),

          // ── 2. Content Body ──
          // 关联书单随附加字段腿到达后并入快捷入口区（非空才出现
          // "关联书单"一行，点击进 RelatedBooklistsScreen——与相似
          // 书籍同款交互）。
          BookInfoSection(
            book: book,
            relatedBooklists: bookDetailRelatedBooklists(
              extrasAsync?.valueOrNull,
            ),
          ),
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
