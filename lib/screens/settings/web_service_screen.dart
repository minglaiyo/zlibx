import 'dart:async';
import 'dart:io';

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

  /// Addresses for the server to bind, one socket each (see
  /// [WebService.start]): the loopback, so the phone's own browser
  /// keeps working, plus every detected address — primary first, then
  /// the others, including the mobile-data one (it is reachable from
  /// the computer on this phone, despite the old "unreachable" label).
  /// Deduplicated, usable IPv4 only. Null when nothing was detected:
  /// the service then falls back to its single 0.0.0.0 socket.
  List<InternetAddress>? _bindAddresses(LanSelection? selection) {
    if (selection == null) return null;
    final seen = <String>{InternetAddress.loopbackIPv4.address};
    final addresses = <InternetAddress>[InternetAddress.loopbackIPv4];
    void add(String address) {
      if (!isUsableIPv4(address)) return;
      if (!seen.add(address)) return;
      addresses.add(InternetAddress(address));
    }

    final primary = selection.primary;
    if (primary != null) add(primary.address);
    for (final candidate in selection.others) {
      add(candidate.address);
    }
    return addresses;
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      // Detect first: the bind list comes from the detected
      // addresses, and a hotspot address changes when the hotspot is
      // re-enabled, so the QR code must be regenerated.
      await _detectNetwork();
      final snapshot = await _buildSnapshot();
      await _service.start(
        snapshot: snapshot,
        strings: _pageStrings(t),
        bindAddresses: _bindAddresses(_selection),
      );
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

  /// Freeze the three lists at the moment the service starts.
  Future<WebSnapshot> _buildSnapshot() async {
    final tasks = ref.read(downloadProvider);
    final saved = await _loadSaved();
    final booklists = await _loadBooklists();
    return WebSnapshot.build(tasks: tasks, saved: saved, booklists: booklists);
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
