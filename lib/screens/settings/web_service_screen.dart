import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklists_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/saved_books_notifier.dart';
import '../../providers/zlibrary_provider.dart';
import '../../services/booklist_repository.dart';
import '../../services/lan_share.dart';
import '../../services/network_state_channel.dart';
import '../../services/web_service.dart';
import '../../utils/app_snack.dart';
import '../../utils/diagnostics.dart';

/// Settings → Web service.
///
/// This page only displays state and forwards the user's actions
/// (start / stop / copy / open). The server itself is the process
/// singleton [WebService.shared]: leaving this page must NOT stop it,
/// so there is deliberately no stop call in dispose(), and initState
/// restores the running state from the singleton.
class WebServiceScreen extends ConsumerStatefulWidget {
  const WebServiceScreen({super.key});

  @override
  ConsumerState<WebServiceScreen> createState() => _WebServiceScreenState();
}

class _WebServiceScreenState extends ConsumerState<WebServiceScreen> {
  final WebService _service = WebService.shared;

  LanSelection? _selection;
  List<String>? _clients;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    // Coming back to the page while the server runs: show it as
    // running, with a freshly detected address.
    if (_service.isRunning) unawaited(_detectNetwork());
  }

  @override
  void dispose() {
    // Only detach this page's listener. The service keeps running.
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  /// Pick the address to show (and re-read connected clients). Called
  /// on every start (a hotspot address changes when the hotspot is
  /// re-enabled, so the QR code must be regenerated) and on demand.
  Future<void> _detectNetwork() async {
    final info = await NetworkStateChannel.lanAddressInfo();
    final fallback = info == null
        ? await NetworkStateChannel.fallbackInterfaces()
        : const <LanCandidate>[];
    final selection = selectLanAddress(info, fallback: fallback);
    final clients = await NetworkStateChannel.arpClients(
      device: selection.primary?.name,
    );
    if (!mounted) return;
    setState(() {
      _selection = selection;
      _clients = clients;
    });
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      // Detect first: the hotspot address changes when the hotspot is
      // re-enabled, so the QR code must be regenerated.
      await _detectNetwork();
      final built = await _buildSnapshot();
      // Capture the long-lived objects now, not the widget's ref:
      // the callbacks below may run after this page is left, when
      // the ref is dead. The notifier and the repository both live
      // in the ProviderContainer, so holding them is safe.
      final notifier = ref.read(downloadProvider.notifier);
      final repository = BooklistRepository(ref.read(zlibraryApiProvider));
      final bookById = built.bookById;
      final booklistById = built.booklistById;
      await _service.start(
        snapshot: built.snapshot,
        strings: _pageStrings(t),
        onRequestDownload: (bookId) =>
            _requestDownload(notifier, bookById, bookId),
        onFetchBooklistPage: (booklistId, page) =>
            _fetchBooklistPage(repository, booklistById, booklistId, page),
      );
    } on LocalNetworkPermissionDenied {
      logIgnored('web_service_screen', 'local network permission denied');
      if (mounted) {
        showAppSnack(context, t.webServiceLocalNetworkDenied, error: true);
      }
    } catch (error) {
      logIgnored('web_service_screen', error);
      if (mounted) {
        showAppSnack(
          context,
          t.webServiceStartFailed(_startErrorText(error)),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What the failure snackbar shows: the native bind reason when
  /// the platform has one (e.g. "Permission denied"), else the error
  /// type. The native side reports BIND_FAILED with the cause.
  String _startErrorText(Object error) {
    if (error is PlatformException) return error.message ?? error.code;
    return error.runtimeType.toString();
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await _service.stop();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _selection = null;
          _clients = null;
        });
      }
    }
  }

  /// Freeze the three lists at the moment the service starts, plus
  /// the lookups the web callbacks need (book id -> Book, booklist
  /// id -> Booklist) so a web request can find the real objects.
  Future<
    ({
      WebSnapshot snapshot,
      Map<int, Book> bookById,
      Map<String, Booklist> booklistById,
    })
  >
  _buildSnapshot() async {
    final tasks = ref.read(downloadProvider);
    final saved = await _loadSaved();
    final booklists = await _loadBooklists();
    final bookById = <int, Book>{};
    for (final book in saved) {
      bookById[book.id] = book;
    }
    final booklistById = <String, Booklist>{};
    for (final list in booklists) {
      booklistById[list.id] = list;
      for (final book in list.previewBooks) {
        bookById[book.id] = book;
      }
    }
    return (
      snapshot: WebSnapshot.build(tasks: tasks, saved: saved, booklists: booklists),
      bookById: bookById,
      booklistById: booklistById,
    );
  }

  /// Web-triggered download (item 3): enqueue the book with the
  /// app's own download logic. Never starts a second round for a
  /// book that is already on this phone or already downloading —
  /// the caller reports that instead. [notifier] and [bookById] are
  /// captured at start time so this keeps working after the page
  /// is left.
  Future<WebDownloadRequest> _requestDownload(
    DownloadNotifier notifier,
    Map<int, Book> bookById,
    int bookId,
  ) async {
    final book = bookById[bookId];
    if (book == null) return WebDownloadRequest.notFound;
    final tasks = notifier.tasks;
    for (final task in tasks) {
      if (task.book.id != bookId) continue;
      if (task.status == DownloadStatus.completed && !task.missingFile) {
        return WebDownloadRequest.alreadyDownloaded;
      }
    }
    for (final task in tasks) {
      if (task.book.id != bookId) continue;
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.pending ||
          task.status == DownloadStatus.paused) {
        return WebDownloadRequest.alreadyDownloading;
      }
    }
    // Fire and forget: startDownload returns the round's future,
    // which only settles when the whole file is down. The web page
    // answers "started" at once.
    unawaited(notifier.startDownload(book));
    return WebDownloadRequest.started;
  }

  /// One booklist page from Z-Library (item 6), reusing the
  /// repository's own calls: page 1 is the server-rendered detail
  /// document, page 2+ is the JSON endpoint. Any failure returns
  /// null and the service falls back to the snapshot's preview
  /// books. [hasMore] is `page < totalPages`.
  Future<WebBooklistPage?> _fetchBooklistPage(
    BooklistRepository repository,
    Map<String, Booklist> booklistById,
    String booklistId,
    int page,
  ) async {
    final list = booklistById[booklistId];
    if (list == null) return null;
    try {
      if (page <= 1) {
        final response = await repository.fetchDetailBooks(list);
        if (!response.success || response.data == null) return null;
        final books = response.data!;
        return WebBooklistPage(books: books, hasMore: books.length >= 20);
      }
      final response = await repository.fetchBooksPage(
        booklistId,
        page: page,
      );
      if (!response.success || response.data == null) return null;
      final data = response.data!;
      final totalPages = data.totalPages;
      return WebBooklistPage(
        books: data.books,
        hasMore: page < totalPages,
      );
    } catch (error) {
      logIgnored('web_service_screen', error);
      return null;
    }
  }

  /// The shelf may still be loading on a cold start; wait briefly.
  Future<List<Book>> _loadSaved() async {
    for (var i = 0; i < 40; i++) {
      final state = ref.read(savedBooksProvider);
      if (!state.isLoading) return state.valueOrNull ?? const <Book>[];
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return ref.read(savedBooksProvider).valueOrNull ?? const <Book>[];
  }

  /// The user's own booklists (the controller is auto-dispose, so hold
  /// a subscription while it loads), with a page cap.
  Future<List<Booklist>> _loadBooklists() async {
    final done = Completer<void>();
    final sub = ref.listenManual<BooklistsState>(booklistsControllerProvider, (
      _,
      next,
    ) {
      if (next.phase != BooklistsPhase.loading && !done.isCompleted) {
        done.complete();
      }
    }, fireImmediately: true);
    try {
      await done.future.timeout(const Duration(seconds: 8));
      final controller = ref.read(booklistsControllerProvider.notifier);
      for (var i = 0; i < 20; i++) {
        final s = sub.read();
        if (s.phase != BooklistsPhase.ready || !s.hasMore) break;
        await controller.loadMore();
      }
      final state = sub.read();
      return state.phase == BooklistsPhase.ready
          ? List<Booklist>.of(state.lists)
          : const <Booklist>[];
    } on TimeoutException {
      return const <Booklist>[];
    } finally {
      sub.close();
    }
  }

  WebPageStrings _pageStrings(AppLocalizations t) => WebPageStrings(
    homeTitle: t.webPageHome,
    downloadedSection: t.webPageDownloaded,
    librarySection: t.webPageLibrary,
    booklistSection: t.webPageBooklists,
    download: t.webPageDownload,
    read: t.webPageRead,
    notDownloaded: t.webPageNotDownloaded,
    empty: t.webPageEmpty,
    backHome: t.webPageBackHome,
    officialLink: t.webPageOfficialLink,
    previewNote: t.webPagePreviewNote,
    notFound: t.webPageNotFound,
    convertFailed: t.webPageConvertFailed,
  );

  Future<void> _copy(String url) async {
    final t = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showAppSnack(context, t.webServiceCopied);
  }

  String _labelFor(LanKind kind, AppLocalizations t) {
    switch (kind) {
      case LanKind.hotspot:
        return t.webServiceUrlHotspot;
      case LanKind.wifi:
        return t.webServiceUrlWifi;
      case LanKind.lan:
        return t.webServiceUrlLan;
      case LanKind.cellular:
      case LanKind.other:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final running = _service.isRunning;
    final port = _service.port;
    final selection = _selection;
    final snapshot = _service.snapshot;

    return Scaffold(
      appBar: AppBar(title: Text(t.webService)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.webServiceSubtitle, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  running ? t.webServiceRunning : t.webServiceStopped,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : (running ? _stop : _start),
                child: Text(running ? t.webServiceStop : t.webServiceStart),
              ),
            ],
          ),
          if (running && port != null) ...[
            const SizedBox(height: 16),
            _primaryArea(t, cs, selection, port),
            const SizedBox(height: 12),
            if (_clients != null)
              Text(
                t.webServiceClients(_clients!.join(', ')),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            const SizedBox(height: 8),
            // Always shown: works even when the client list is unknown.
            Text(t.webServiceSelfCheck, style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _detectNetwork,
                icon: const Icon(Icons.refresh),
                label: Text(t.webServiceRefreshNetwork),
              ),
            ),
            if (selection != null && selection.others.isNotEmpty)
              _otherAddresses(t, selection.others, port),
            const Divider(height: 32),
            Text(
              t.webServiceCounts(
                snapshot.downloadedCount,
                snapshot.libraryCount,
                snapshot.booklistCount,
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              t.webServiceSnapshotNote,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  /// ONE labelled URL + ONE QR code, or the "turn on hotspot" hint.
  Widget _primaryArea(
    AppLocalizations t,
    ColorScheme cs,
    LanSelection? selection,
    int port,
  ) {
    final primary = selection?.primary;
    if (selection == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (primary == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.webServiceNoNetwork),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openLocal(port),
            icon: const Icon(Icons.open_in_browser),
            label: Text(t.webServiceOpenLocal),
          ),
        ],
      );
    }
    final url = lanUrl(primary.address, port);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _labelFor(primary.kind, t),
          style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SelectableText(url, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            // A new QR is built from the current URL on every rebuild,
            // so it always matches the address after a restart.
            child: QrImageView(data: url, size: 200),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _copy(url),
              icon: const Icon(Icons.copy),
              label: Text(t.webServiceCopyUrl),
            ),
            OutlinedButton.icon(
              onPressed: () => _openLocal(port),
              icon: const Icon(Icons.open_in_browser),
              label: Text(t.webServiceOpenLocal),
            ),
          ],
        ),
      ],
    );
  }

  Widget _otherAddresses(
    AppLocalizations t,
    List<LanCandidate> others,
    int port,
  ) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(t.webServiceOtherUrls),
      children: [
        for (final c in others)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(lanUrl(c.address, port)),
            // Every listed address is bound by the server, including
            // the mobile-data one, so each gets a copy button.
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: t.webServiceCopyUrl,
              onPressed: () => _copy(lanUrl(c.address, port)),
            ),
          ),
      ],
    );
  }

  Future<void> _openLocal(int port) async {
    try {
      await launchUrl(
        Uri.parse('http://127.0.0.1:$port/'),
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      logIgnored('web_service_screen', error);
    }
  }
}
