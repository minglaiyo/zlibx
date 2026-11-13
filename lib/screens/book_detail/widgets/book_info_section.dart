import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../core/book_description.dart';
import '../../../models/display_book.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../l10n/book_categories.dart';
import '../../../routes/app_routes.dart';
import '../../../providers/settings_provider.dart';
import '../../search/search_screen.dart';
import '../../similar/similar_books_screen.dart';
import '../../comments/book_comments_screen.dart';
import 'add_to_booklist_dialog.dart';
import 'book_detail_content.dart';

class BookInfoSection extends ConsumerStatefulWidget {
  final Book book;

  const BookInfoSection({
    super.key,
    required this.book,
  });

  @override
  ConsumerState<BookInfoSection> createState() => _BookInfoSectionState();
}

class _BookInfoSectionState extends ConsumerState<BookInfoSection> {
  /// 简介折叠开关开启时：true = 已点书名展开全文。开关本身是持久
  /// 设置（collapseDetailDescriptionProvider），这里的 reveal 只影响
  /// 当前页面的显示。
  bool _descriptionRevealed = false;

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
      if (book.publisher?.isNotEmpty ?? false)
        l10n.publisher: book.publisher!,
      if (book.pages != null && book.pages != 0)
        l10n.pages: '${book.pages}',
      if (book.language?.isNotEmpty ?? false)
        l10n.language: book.language!,
      // Detail-page-only metadata (parsed from the detail HTML, not
      // the eapi): shown only when the fetch returned them.
      if (book.volume?.isNotEmpty ?? false)
        l10n.volume: book.volume!,
      if (book.isbn13?.isNotEmpty ?? false)
        l10n.isbn13: book.isbn13!,
      if (book.isbn10?.isNotEmpty ?? false)
        l10n.isbn10: book.isbn10!,
      // Both CIDs on their own labelled lines: the Blake2b CID must
      // stay reachable, never silently dropped. Display-only for v1
      // (BookPublicationInfo has no tap-to-copy).
      if (book.ipfsCid?.isNotEmpty ?? false)
        l10n.ipfs: [
          'CID: ${book.ipfsCid!}',
          if (book.ipfsCidBlake2b?.isNotEmpty ?? false)
            'CID Blake2b: ${book.ipfsCidBlake2b!}',
        ].join('\n'),
    };
    // A missing description must stay absent rather than rendering as
    // the literal word "null".
    final description = normalizedBookDescription(book.description);
    final collapseDescription = ref.watch(collapseDetailDescriptionProvider);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookDetailHeading(
              book: book.toDisplay(),
              subtitle: book.series,
              // Tapping the author searches for that author (the
              // heading only shows the author when it is non-empty,
              // so the callback can only fire then).
              onAuthorTap: book.author?.isNotEmpty ?? false
                  ? () => AppRoutes.openSearchWithQuery(context, book.author!)
                  : null,
              // 简介折叠开关开启时点书名切换展开/收起（功能 1），
              // 标题带主色提示可点；开关关闭时标题纯展示。
              onTitleTap: collapseDescription
                  ? () =>
                      setState(() => _descriptionRevealed = !_descriptionRevealed)
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
            if (description != null &&
                (!collapseDescription || _descriptionRevealed)) ...[
              const SizedBox(height: 28),
              // 折叠模式下经书名展开：直接出全文（开合按钮保留）。
              BookDetailDescription(
                text: description,
                initiallyExpanded: collapseDescription && _descriptionRevealed,
              ),
            ],
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 28),
              BookPublicationInfo(
                fields: fields,
                // Tapping the publisher searches for that publisher
                // (the key is the same localized label used for the
                // row above, so it can only match that row).
                onFieldTap: book.publisher?.isNotEmpty ?? false
                    ? {
                        l10n.publisher: () => AppRoutes.openSearchWithQuery(
                          context,
                          book.publisher!,
                        ),
                      }
                    : null,
              ),
            ],
            if (book.hash?.isNotEmpty ?? false) ...[
              const SizedBox(height: 24),
              Divider(
                height: 1,
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.auto_stories_outlined,
                  color: cs.primary,
                  size: 22,
                ),
                title: Text(
                  l10n.similarBooks,
                  style: const TextStyle(fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: () => AppRoutes.openSimilarBooks(
                  context,
                  SimilarBooksArgs(
                    bookId: book.id,
                    hashId: book.hash!,
                    bookTitle: book.title,
                  ),
                ),
              ),
            ],
            // Add this book to one of the user's own booklists.
            const SizedBox(height: 8),
            Divider(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.collections_bookmark_outlined,
                color: cs.primary,
                size: 22,
              ),
              title: Text(
                l10n.addToBooklist,
                style: const TextStyle(fontSize: 15),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => _addToBooklist(context, book),
            ),
            // Book comments (Z-Library site comments, view-only).
            const SizedBox(height: 8),
            Divider(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.comment_outlined,
                color: cs.primary,
                size: 22,
              ),
              title: Text(
                l10n.comments,
                style: const TextStyle(fontSize: 15),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => AppRoutes.openBookComments(
                context,
                BookCommentsArgs(
                  bookId: book.id,
                  bookTitle: book.title,
                ),
              ),
            ),
          ],
        ),
      ),
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
