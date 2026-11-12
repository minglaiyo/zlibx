import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../core/book_description.dart';
import '../../../models/display_book.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../l10n/book_categories.dart';
import '../../../providers/category_books_provider.dart';
import '../../../routes/app_routes.dart';
import '../../similar/similar_books_screen.dart';
import '../../comments/book_comments_screen.dart';
import 'add_to_booklist_dialog.dart';
import 'book_detail_content.dart';

class BookInfoSection extends StatelessWidget {
  final Book book;

  const BookInfoSection({
    super.key,
    required this.book,
  });

  @override
  Widget build(BuildContext context) {
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
      // Detail-page rating (site header block `★ 3.0 / 5.0`): interest
      // over quality. The interest side falls back to the eapi interest
      // score (the ★ the search card shows) when the detail HTML fetch
      // failed — see book_detail_screen.dart; quality is HTML-only.
      // Shown when either score exists; the site hides each span
      // independently for unrated books, and the parser nulls them.
      if ((book.ratingInterest?.isNotEmpty ?? false) ||
          (book.ratingQuality?.isNotEmpty ?? false))
        BookDetailTag(
          icon: Icons.star_rounded,
          text: _ratingText(book),
        ),
      // Website categories (eapi `categories`, e.g. `{307: History -
      // World history}`): one chip per category, localized to the app
      // language (zh / zh_Hant via the category table; other locales show
      // the English name from the API). A chip with a parsed id opens
      // that category's book list; a plain name without an id stays
      // display-only.
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
          onTap: () => AppRoutes.openCategoryBooks(
            context,
            CategoryBooksArgs(
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

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookDetailHeading(book: book.toDisplay(), subtitle: book.series),
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
            if (description != null) ...[
              const SizedBox(height: 28),
              BookDetailDescription(text: description),
            ],
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 28),
              BookPublicationInfo(fields: fields),
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

/// The rating tag's text, in the site's own `interest / quality`
/// shape; a missing score collapses to the one that exists (the site
/// hides each span independently, so a one-sided rating is real).
String _ratingText(Book book) {
  final interest = book.ratingInterest;
  final quality = book.ratingQuality;
  if (interest != null && interest.isNotEmpty && quality != null &&
      quality.isNotEmpty) {
    return '$interest / $quality';
  }
  if (interest != null && interest.isNotEmpty) return interest;
  return quality ?? '';
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
