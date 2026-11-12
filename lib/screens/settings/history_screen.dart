import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../providers/books_provider.dart';
import '../../widgets/cover_placeholder.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/empty_state.dart';
import '../../routes/app_routes.dart';
import '../../l10n/generated/app_localizations.dart';

import '../../utils/cover_cache.dart';

/// Sort order for the cloud download history list. The default
/// ([dateDesc]) is the server's own order (newest download first —
/// the `/users/downloads` per-download log is already sorted that way).
enum _HistorySort {
  dateDesc,
  dateAsc,
  titleAsc,
  titleDesc,
  year,
  sizeDesc,
  sizeAsc,
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  _HistorySort _sort = _HistorySort.dateDesc;

  @override
  void initState() {
    super.initState();
    // 云端列表是账号维度的：页面缓存期间，其他设备（或本机刚完成
    // 的下载）都可能添了新记录，打开页面时静默对账一次，老列表保持
    // 可见、新记录补进来。首次打开不用——build() 自己就会拉取，
    // is! AsyncLoading 恰好把这种情况排除。
    Future.microtask(() {
      if (!mounted) return;
      if (ref.read(downloadedBooksProvider) is! AsyncLoading) {
        ref
            .read(downloadedBooksProvider.notifier)
            .loadDownloadedBooks(silent: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // This provider gets "downloaded" books from account (Cloud history)
    final downloadedBooksAsync = ref.watch(downloadedBooksProvider);

    return Scaffold(
      appBar: GradientAppBar(
        title: l10n.downloadHistory,
        actions: [
          IconButton(
            tooltip: l10n.sort,
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: _showSortDialog,
          ),
        ],
      ),
      // 下拉手动对账：silent 拉取，老列表保持可见，不闪 loading
      // （RefreshIndicator 自己转圈）。loading / 空态不可拉，打开
      // 页面时的静默对账会补上这两处的刷新。
      body: RefreshIndicator(
        onRefresh: () => ref
            .read(downloadedBooksProvider.notifier)
            .loadDownloadedBooks(silent: true),
        child: downloadedBooksAsync.when(
          data: (books) {
            if (books.isEmpty) {
              return EmptyState(
                icon: Icons.history,
                title: l10n.noHistory,
                message: l10n.historyEmptyMessage,
              );
            }

            final sorted = _sortedBooks(books);
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: sorted.length,
              itemBuilder: (context, index) {
                final book = sorted[index];

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(12),
                    leading: _HistoryCoverThumb(book: book),
                    title: Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 每次下载的时间（dstats 记录自带；eapi 元数据
                        // 记录没有）。纯数字格式，无需本地化字符串。
                        if (book.downloadedAt != null)
                          Text(
                            _formatStamp(book.downloadedAt!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (book.author != null) Text(book.author!),
                        if (book.filesizeString != null)
                          Text(
                            '${book.extension?.toUpperCase()} • ${book.filesizeString}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      AppRoutes.openBookDetailForBook(context, book);
                    },
                  ),
                );
              },
            );
          },
          loading: () => LoadingWidget(message: l10n.loadingDownloads),
          error: (error, stack) => EmptyState(
            icon: Icons.error_outline,
            title: l10n.error,
            message: error.toString(),
          ),
        ),
      ),
    );
  }

  /// `yyyy-MM-dd HH:mm`，与 dstats 页面渲染的是同一时刻（解析时未做
  /// 时区换算，展示原样回放，不会漂移）。
  static String _formatStamp(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  List<Book> _sortedBooks(List<Book> books) {
    switch (_sort) {
      case _HistorySort.dateDesc:
        // Server order is already newest first.
        return books;
      case _HistorySort.dateAsc:
        return books.reversed.toList();
      case _HistorySort.titleAsc:
      case _HistorySort.titleDesc:
        final sorted = [...books]
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        return _sort == _HistorySort.titleAsc
            ? sorted
            : sorted.reversed.toList();
      case _HistorySort.year:
        return [...books]..sort(_compareYear);
      case _HistorySort.sizeDesc:
        return [...books]
          ..sort((a, b) => _compareSize(a, b, descending: true));
      case _HistorySort.sizeAsc:
        return [...books]
          ..sort((a, b) => _compareSize(a, b, descending: false));
    }
  }

  /// Year, newest first; books without a year sort last.
  static int _compareYear(Book a, Book b) {
    final x = a.year;
    final y = b.year;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return y.compareTo(x);
  }

  /// File size; books without a known size sort last either way.
  static int _compareSize(Book a, Book b, {required bool descending}) {
    final x = a.filesize;
    final y = b.filesize;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return descending ? y.compareTo(x) : x.compareTo(y);
  }

  String _sortLabel(AppLocalizations l10n, _HistorySort sort) =>
      switch (sort) {
        _HistorySort.dateDesc => l10n.historySortDateDesc,
        _HistorySort.dateAsc => l10n.historySortDateAsc,
        _HistorySort.titleAsc => l10n.historySortTitleAsc,
        _HistorySort.titleDesc => l10n.historySortTitleDesc,
        _HistorySort.year => l10n.year,
        _HistorySort.sizeDesc => l10n.historySortSizeDesc,
        _HistorySort.sizeAsc => l10n.historySortSizeAsc,
      };

  /// Sort picker, in the project's own dialog idiom (see the domain
  /// selector): dense ListTile rows, the selected row marked with a
  /// leading check_circle in the primary color and a bold primary
  /// title. Tapping a row applies the sort and closes the dialog.
  Future<void> _showSortDialog() async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          title: Text(
            l10n.sort,
            style: const TextStyle(fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _HistorySort.values.map((sort) {
              final selected = sort == _sort;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -2),
                leading: selected
                    ? Icon(
                        Icons.check_circle,
                        color: cs.primary,
                        size: 20,
                      )
                    : const Icon(
                        Icons.circle_outlined,
                        size: 20,
                        color: Colors.grey,
                      ),
                title: Text(
                  _sortLabel(l10n, sort),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: selected ? cs.primary : null,
                  ),
                ),
                onTap: () {
                  setState(() => _sort = sort);
                  Navigator.pop(dialogContext);
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }
}

/// Leading cover for one cloud history row. Tries the listed cover
/// first; when it fails, resolves the detail endpoint's cover once
/// and swaps to it. A row with no listed cover keeps the plain icon.
class _HistoryCoverThumb extends ConsumerWidget {
  const _HistoryCoverThumb({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = ref.watch(
      historyCoverProvider.select((covers) => covers[book.id.toString()]),
    );
    final cover = resolved ?? book.cover;
    if (cover == null || cover.isEmpty) {
      return const Icon(Icons.book, size: 50);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: cover,
        width: 50,
        height: 70,
        fit: BoxFit.cover,
        memCacheWidth: coverCacheWidth(50, context),
        memCacheHeight: coverCacheHeight(70, context),
        placeholder: (context, url) => const CoverPlaceholder.static(),
        errorWidget: (context, url, error) {
          if (resolved == null) {
            ref.read(historyCoverProvider.notifier).resolveCover(book);
          }
          return const CoverPlaceholder.static();
        },
      ),
    );
  }
}
