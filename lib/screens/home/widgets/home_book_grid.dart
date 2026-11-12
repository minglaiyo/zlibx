import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../routes/app_routes.dart';
import '../../../widgets/book_card.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/entrance.dart';
import '../../../widgets/loading_widget.dart';

/// The recommendation grid plus its empty / loading / error states.
class HomeBookGrid extends StatelessWidget {
  const HomeBookGrid({
    super.key,
    required this.booksAsync,
    required this.topPadding,
    required this.scrollController,
    required this.onRefresh,
  });

  final AsyncValue<List<DisplayBook>> booksAsync;
  final double topPadding;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // topPadding reserves the floating glass header's height inside the
    // scrollable, so the grid scrolls underneath the header (blurred)
    // instead of starting below it.
    return booksAsync.when(
      data: (books) {
        if (books.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(40, topPadding + 40, 40, 40),
            child: EmptyState(
              icon: Icons.book_outlined,
              title: AppLocalizations.of(context)!.noBooksFound,
            ),
          );
        }

        final itemCount = books.length;

        return LayoutBuilder(
          builder: (context, constraints) {
            const maxCardWidth = 220.0;
            const columnSpacing = 16.0;
            const horizontalPadding = 20.0;
            final gridWidth = (constraints.maxWidth - horizontalPadding * 2)
                .clamp(0.0, double.infinity);
            final columnCount = (gridWidth / (maxCardWidth + columnSpacing))
                .ceil()
                .clamp(1, double.infinity);
            final cardWidth =
                ((gridWidth - columnSpacing * (columnCount - 1)) / columnCount)
                    .clamp(0.0, double.infinity);

            return RefreshIndicator(
              onRefresh: onRefresh,
              // The spinner must appear below the floating glass header,
              // not behind it (the header paints on top of the grid).
              edgeOffset: topPadding,
              child: GridView.builder(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, topPadding, 20, 96),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxCardWidth,
                  mainAxisExtent: BookCard.compactHeightFor(cardWidth),
                  crossAxisSpacing: columnSpacing,
                  mainAxisSpacing: 12,
                ),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  final book = books[index];
                  return EntranceSlideFade(
                    index: index,
                    child: BookCard(
                      book: book,
                      compact: true,
                      showSourceBadge: true,
                      onTap: () {
                        AppRoutes.openBookDetailForDisplayBook(context, book);
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.only(top: topPadding + 40, bottom: 40),
        child: LoadingWidget(
          message: AppLocalizations.of(context)!.loadingTrendingBooks,
        ),
      ),
      error: (error, stack) => Padding(
        padding: EdgeInsets.fromLTRB(20, topPadding + 20, 20, 20),
        child: EmptyState(
          icon: Icons.error_outline,
          title: AppLocalizations.of(context)!.couldNotLoadBooks,
          message: AppLocalizations.of(context)!.checkYourConnection,
        ),
      ),
    );
  }
}
