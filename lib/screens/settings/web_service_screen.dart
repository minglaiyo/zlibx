import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/download_provider.dart';
import '../../providers/saved_books_notifier.dart';
import '../../services/lan_share.dart';
import '../../services/network_state_channel.dart';
import '../../services/web_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_snack.dart';
import '../../utils/diagnostics.dart';
import 'widgets/settings_card.dart';

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
      final built = WebSnapshot.build(
        tasks: ref.read(downloadProvider),
        saved: await _loadSaved(),
      );
      // Capture the long-lived objects now, not the widget's ref:
      // callbacks may run after this page is left, when ref is dead.
      final notifier = ref.read(downloadProvider.notifier);
      final savedNotifier = ref.read(savedBooksProvider.notifier);
      await _service.start(
        snapshot: built,
        strings: _pageStrings(t),
        snapshotProvider: () => WebSnapshot.build(
          tasks: notifier.tasks,
          saved: savedNotifier.books,
        ),
        tasksProvider: () => notifier.tasks,
        onRequestDownload: (bookId) =>
            _requestDownload(notifier, savedNotifier, bookId),
        onTaskAction: (taskId, action) => _taskAction(notifier, taskId, action),
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

  /// Web-triggered downloads use the app's own engine and a live shelf
  /// lookup, so favourites added after service startup are available.
  /// The captured notifiers remain valid after this page is left.
  Future<WebDownloadRequest> _requestDownload(
    DownloadNotifier notifier,
    SavedBooksNotifier savedNotifier,
    int bookId,
  ) async {
    Book? book;
    for (final candidate in savedNotifier.books) {
      if (candidate.id == bookId) {
        book = candidate;
        break;
      }
    }
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

  Future<bool> _taskAction(
    DownloadNotifier notifier,
    String taskId,
    WebTaskAction action,
  ) async {
    DownloadTask? task;
    for (final candidate in notifier.tasks) {
      if (candidate.id == taskId) {
        task = candidate;
        break;
      }
    }
    if (task == null) {
      if (action != WebTaskAction.cancel) return false;
      final bookId = int.tryParse(taskId);
      if (bookId == null) return false;
      notifier.cancelDownloadRequest(bookId);
      return true;
    }
    if (action == WebTaskAction.cancel) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.error ||
          task.status == DownloadStatus.cancelled) {
        await notifier.removeTask(taskId);
      } else {
        notifier.cancelDownloadRequest(task.book.id);
      }
      return true;
    }
    if (task.status == DownloadStatus.paused) {
      notifier.resumeDownload(taskId);
      return true;
    }
    if (!task.canRetry && !task.wifiOnlyBlocked) return false;
    unawaited(
      notifier.startDownload(
        task.book,
        presetUrl: task.presetUrl,
        fallbackUrls: task.fallbackUrls,
        source: task.source,
        customSubfolder: task.customSubfolder,
      ),
    );
    return true;
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

  WebPageStrings _pageStrings(AppLocalizations t) => WebPageStrings(
    homeTitle: t.webPageHome,
    downloadedSection: t.webPageDownloaded,
    librarySection: t.webPageLibrary,
    download: t.webPageDownload,
    read: t.webPageRead,
    notDownloaded: t.webPageNotDownloaded,
    empty: t.webPageEmpty,
    backHome: t.webPageBackHome,
    notFound: t.webPageNotFound,
    convertFailed: t.webPageConvertFailed,
  );

  String _withAccessToken(String url) {
    final token = _service.accessToken;
    return token == null ? url : '$url?t=${Uri.encodeQueryComponent(token)}';
  }

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
    ref.listen(downloadProvider, (_, __) {
      if (_service.isRunning) _service.refreshSnapshot();
    });
    ref.listen(savedBooksProvider, (_, __) {
      if (_service.isRunning) _service.refreshSnapshot();
    });
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final running = _service.isRunning;
    final port = _service.port;
    final selection = _selection;
    final snapshot = _service.snapshot;

    return Scaffold(
      appBar: AppBar(title: Text(t.webService)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _statusCard(t, cs, running),
          if (running && port != null) ...[
            const SizedBox(height: AppSpacing.xl),
            _addressCard(t, cs, selection, port),
            const SizedBox(height: AppSpacing.xl),
            _statsCard(t, cs, snapshot),
            const SizedBox(height: AppSpacing.xl),
            _selfCheckCard(t),
          ],
        ],
      ),
    );
  }

  /// Status, in the settings page's own language: a flat bordered
  /// card with a leading icon, a status dot (green while running,
  /// muted otherwise) and the start/stop button. The subtitle says
  /// what the service does.
  Widget _statusCard(AppLocalizations t, ColorScheme cs, bool running) {
    final statusColor = running ? AppColors.success : cs.onSurfaceVariant;
    return SettingsCard(
      child: ListTile(
        leading: Icon(
          Icons.wifi_tethering_rounded,
          color: running ? AppColors.success : cs.onSurfaceVariant,
        ),
        title: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              running ? t.webServiceRunning : t.webServiceStopped,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        subtitle: Text(
          t.webServiceSubtitle,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        trailing: FilledButton(
          onPressed: _busy ? null : (running ? _stop : _start),
          child: Text(running ? t.webServiceStop : t.webServiceStart),
        ),
      ),
    );
  }

  /// The address block: one labelled URL + QR code, the copy / open
  /// actions, connected devices, and the other addresses. While the
  /// address is still being detected, a spinner; with no usable
  /// network, the hint plus the open-in-browser button.
  Widget _addressCard(
    AppLocalizations t,
    ColorScheme cs,
    LanSelection? selection,
    int port,
  ) {
    final primary = selection?.primary;
    if (selection == null) {
      return const SettingsCard(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (primary == null) {
      return SettingsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.wifi_off_rounded),
              title: Text(t.webServiceNoNetwork),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: OutlinedButton.icon(
                onPressed: () => _openLocal(port),
                icon: const Icon(Icons.open_in_browser),
                label: Text(t.webServiceOpenLocal),
              ),
            ),
          ],
        ),
      );
    }
    final url = _withAccessToken(lanUrl(primary.address, port));
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: Text(
              _labelFor(primary.kind, t),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: SelectableText(
              url,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Center(
            child: Container(
              // White on purpose: a QR code needs a light quiet zone
              // to scan, in dark mode too.
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              // A new QR is built from the current URL on every rebuild,
              // so it always matches the address after a restart.
              child: QrImageView(data: url, size: 200),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
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
                TextButton.icon(
                  onPressed: _detectNetwork,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.webServiceRefreshNetwork),
                ),
              ],
            ),
          ),
          if (_clients != null) ...[
            const SettingsDivider(),
            ListTile(
              leading: const Icon(Icons.devices_rounded),
              title: Text(t.webServiceClients(_clients!.join(', '))),
            ),
          ],
          if (selection.others.isNotEmpty) ...[
            const SettingsDivider(),
            _otherAddresses(t, selection.others, port),
          ],
        ],
      ),
    );
  }

  /// Live snapshot counts and the local-network security notice.
  Widget _statsCard(AppLocalizations t, ColorScheme cs, WebSnapshot snapshot) {
    const countStyle = TextStyle(fontWeight: FontWeight.w600);
    return SettingsCard(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: Text(t.webPageDownloaded),
            trailing: Text('${snapshot.downloadedCount}', style: countStyle),
          ),
          const SettingsDivider(),
          ListTile(
            leading: const Icon(Icons.library_books_rounded),
            title: Text(t.webPageLibrary),
            trailing: Text('${snapshot.libraryCount}', style: countStyle),
          ),
          const SettingsDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 12, 16, 12),
            child: Text(
              t.webServiceSnapshotNote,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          const SettingsDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
            child: Text(
              t.webServiceSecurityNote,
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Self-check hint.
  Widget _selfCheckCard(AppLocalizations t) {
    return SettingsCard(
      child: ListTile(
        leading: const Icon(Icons.info_outline_rounded),
        title: Text(t.webServiceSelfCheck),
      ),
    );
  }

  Widget _otherAddresses(
    AppLocalizations t,
    List<LanCandidate> others,
    int port,
  ) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(t.webServiceOtherUrls),
      children: [
        for (final c in others)
          Builder(
            builder: (context) {
              final url = _withAccessToken(lanUrl(c.address, port));
              return ListTile(
                dense: true,
                title: Text(url),
                // Every listed address is bound by the server, including
                // the mobile-data one, so each gets a copy button.
                trailing: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: t.webServiceCopyUrl,
                  onPressed: () => _copy(url),
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _openLocal(int port) async {
    try {
      await launchUrl(
        Uri.parse(_withAccessToken('http://127.0.0.1:$port/')),
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      logIgnored('web_service_screen', error);
    }
  }
}
