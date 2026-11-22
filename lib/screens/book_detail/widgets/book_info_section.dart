import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../constants/search_filters.dart';
import '../../../core/book_description.dart';
import '../../../l10n/book_categories.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/settings_provider.dart';
import '../../../routes/app_routes.dart';
import '../../comments/book_comments_screen.dart';
import '../related_booklists_screen.dart' show RelatedBooklistsArgs;
import '../../search/search_screen.dart';
import '../../similar/similar_books_screen.dart';
import 'add_to_booklist_dialog.dart';
import 'book_detail_content.dart';


class BookInfoSection extends ConsumerStatefulWidget {
  final Book book;

  /// 关联书单落地页的抓取键（书的详情页路径，由详情页装配传入）。
  /// 入口行在有 href 时恒显——数据不在详情页抓，点进
  /// [RelatedBooklistsScreen] 才开始（用户定稿 2026-11-20）。
  final String? relatedHref;

  const BookInfoSection({
    super.key,
    required this.book,
    this.relatedHref,
  });

  @override
  ConsumerState<BookInfoSection> createState() => _BookInfoSectionState();
}

class _BookInfoSectionState extends ConsumerState<BookInfoSection> {
  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tags = <Widget>[
      if (book.extension?.isNotEmpty ?? false)
        BookDetailTag(
          icon: Icons.description_outlined,
          text: book.extension!.toUpperCase(),
          highlight: true,
        ),
      if (book.filesizeString?.isNotEmpty ?? false)
        BookDetailTag(icon: Icons.storage_outlined, text: book.filesizeString!),
      if (book.year != null && book.year != 0)
        BookDetailTag(
          icon: Icons.calendar_today_outlined,
          text: '${book.year}',
        ),
      // No rating tag here anymore: the rating lives only on the hero
      // cover badge (DisplayBook.ratingText, interest / quality).
      // Website categories (eapi `categories`, e.g. `{307: History -
      // World history}`): one chip per category, localized to the app
      // language (zh / zh_Hant via the category table; other locales show
      // the English name from the API). A chip with a parsed id opens
      // the search scoped to that category; a plain name without an id
      // stays display-only.
      ...parseBookCategories(book.categories).map((c) {
        final locale = Localizations.localeOf(context);
        final tag = BookDetailTag(
          icon: Icons.category_outlined,
          text: localizedBookCategoryName(c, locale),
        );
        final id = c.id;
        if (id == null) return tag;
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => AppRoutes.openSearchWithCategory(
            context,
            SearchScreenArgs(
              categoryId: id,
              categoryName: localizedBookCategoryName(c, locale),
            ),
          ),
          child: tag,
        );
      }),
    ];
    final fields = <String, String>{
      if (book.publisher?.isNotEmpty ?? false) l10n.publisher: book.publisher!,
      if (book.pages != null && book.pages != 0) l10n.pages: '${book.pages}',
      if (book.language?.isNotEmpty ?? false) l10n.language: book.language!,
      // 卷/ISBN/IPFS 这些书页 HTML 装饰行已随附加字段腿撤下（用户
      // 定稿 2026-11-20：详情页不再为几行装饰抓几百 KB 的 HTML）。
    };

    // A missing description must stay absent rather than rendering as
    // the literal word "null".
    final description = normalizedBookDescription(book.description);
    final quickActionsUp = ref.watch(detailQuickActionsUpProvider);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookDetailHeading(
              book: book.toDisplay(),
              subtitle: book.series,
              // Tapping the author opens the site's author aggregation
              // page (方案 F2：作者全部作品 + 分页); the aggregation
              // screen offers a field-scoped search as its fallback
              // when the site has no such author page.
              onAuthorTap: book.author?.isNotEmpty ?? false
                  ? () => AppRoutes.openAuthor(context, book.author!)
                  : null,
              // Tapping the series opens a field-scoped search for
              // that series (same pattern as the publisher tap below).
              // No series = no tap target, the subtitle stays
              // display-only.
              onSubtitleTap: book.series?.isNotEmpty ?? false
                  ? () => AppRoutes.openSearchWithQuery(
                      context,
                      book.series!,
                      field: SearchField.series,
                    )
                  : null,
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 16),
              // One row, never wrapped below: a category name can be long,
              // so the row scrolls horizontally instead of dropping tags
              // onto a second line.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < tags.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      tags[i],
                    ],
                  ],
                ),
              ),
            ],
            // 快捷入口上移开关（用户批 2026-11-14 两轮调整后的最终形
            // 态）：相似书籍 / 加入书单 / 评论提到标题正下方（首屏直达
            // ）；简介与出版信息保持原位、正常显示——反正都在下面，
            // 不再折叠简介。开关关闭时三行入口保持页面底部原位置。
            if (quickActionsUp) ..._actionTiles(book, l10n, cs),
            if (description != null) ...[
              const SizedBox(height: 28),
              BookDetailDescription(text: description),
            ],
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 28),
              BookPublicationInfo(
                fields: fields,
                // Tap handlers keyed by the row label (the same string
                // used as the map key in [fields]). Tapping the
                // publisher searches for that publisher (field-scoped
                // for the same reason as the author tap above).
                onFieldTap: {
                  if (book.publisher?.isNotEmpty ?? false)
                    l10n.publisher: () => AppRoutes.openSearchWithQuery(
                      context,
                      book.publisher!,
                      field: SearchField.publisher,
                    ),
                },
              ),
            ],
            if (!quickActionsUp) ..._actionTiles(book, l10n, cs),
          ],
        ),
      ),
    );
  }

  /// 相似书籍 / 加入书单 / 评论三行入口（每行 Divider 分隔）。简介
  /// 折叠模式下渲染在标题正下方，否则保持在页面底部（原位置）。
  List<Widget> _actionTiles(Book book, AppLocalizations l10n, ColorScheme cs) {
    final hasSimilar = book.hash?.isNotEmpty ?? false;
    final hasRelated = widget.relatedHref?.isNotEmpty ?? false;
    // 用户定稿 2026-11-19:关联书单紧跟相似书籍之下(加入书单/评论
    // 依次后移)。first 标记 = 列表里实际渲染的第一行,只留一份
    // 顶部 20px 呼吸。
    return [
      if (hasSimilar)
        _actionTile(
          icon: Icons.auto_stories_outlined,
          label: l10n.similarBooks,
          cs: cs,
          first: true,
          onTap: () => AppRoutes.openSimilarBooks(
            context,
            SimilarBooksArgs(
              bookId: book.id,
              hashId: book.hash!,
              bookTitle: book.title,
            ),
          ),
        ),
      // 关联书单：书被收录进的公开书单。入口恒显（有 href 即可点），
      // 数据进落地页才抓（用户定稿 2026-11-20）。
      if (hasRelated)
        _actionTile(
          icon: Icons.collections_outlined,
          label: l10n.relatedBooklists,
          cs: cs,
          first: !hasSimilar,
          onTap: () => AppRoutes.openRelatedBooklists(
            context,
            RelatedBooklistsArgs(href: widget.relatedHref!),
          ),
        ),
      _actionTile(
        icon: Icons.collections_bookmark_outlined,
        label: l10n.addToBooklist,
        cs: cs,
        first: !hasSimilar && !hasRelated,
        // Add this book to one of the user's own booklists.
        onTap: () => _addToBooklist(context, book),
      ),
      // Book comments (Z-Library site comments, view-only).
      _actionTile(
        icon: Icons.comment_outlined,
        label: l10n.comments,
        cs: cs,
        onTap: () => AppRoutes.openBookComments(
          context,
          BookCommentsArgs(bookId: book.id, bookTitle: book.title),
        ),
      ),
    ];
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required ColorScheme cs,
    required VoidCallback onTap,
    bool first = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: first ? 20 : 8),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: cs.primary, size: 22),
          title: Text(label, style: const TextStyle(fontSize: 15)),
          trailing: const Icon(Icons.chevron_right_rounded, size: 20),
          onTap: onTap,
        ),
      ],
    );
  }
}

/// Open the my-booklists picker and add this book to the picked list.
/// The picker handles the API call and its notices; this only navigates
/// to the login page when the picker reports the user is signed out.
Future<void> _addToBooklist(BuildContext context, Book book) async {
  final loginRequested = await showAddToBooklistDialog(context, book.id);
  if (loginRequested && context.mounted) {
    await AppRoutes.openLogin(context);
  }
}
