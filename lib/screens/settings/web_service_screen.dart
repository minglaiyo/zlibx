import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/download_provider.dart';
import '../../services/lan_share.dart';
import '../../services/network_state_channel.dart';
import '../../services/web_keepalive.dart';
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
    // running, with a freshly detected address. The served snapshot
    // itself is kept fresh by the engine-side live source
    // (DownloadNotifier → WebService.markDownloadChanged) — no page
    // needs to be mounted.
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
    // The address may have changed while the server runs (the hotspot
    // was re-enabled): refresh the keep-alive notification so it shows
    // an address that actually works. No-op when the server is off.
    if (_service.isRunning) {
      final primary = selection.primary;
      final port = _service.port;
      if (primary != null && port != null) {
        unawaited(
          WebKeepalive.updateText(lanUrl(primary.address, port)),
        );
      }
    }
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context)!;
    // Captured before any await: the palette reads the theme, and the
    // context must not cross async gaps.
    final palette = _webPalette(context);
    setState(() => _busy = true);
    try {
      // Detect first: the hotspot address changes when the hotspot is
      // re-enabled, so the QR code must be regenerated.
      await _detectNetwork();
      // Capture the long-lived object now, not the widget's ref:
      // the live source below keeps working after this page is left,
      // when the ref is dead. The notifier lives in the
      // ProviderContainer, so holding it is safe.
      final notifier = ref.read(downloadProvider.notifier);
      await _service.start(
        snapshot: await notifier.buildWebSnapshot(),
        strings: _pageStrings(t),
        palette: palette,
        onRequestDownload: notifier.webRequestDownload,
      );
      // Live source: engine-side transitions and shelf changes push a
      // rebuilt snapshot into the running server on their own — the
      // browser catches up on reload even with this page closed (or
      // the phone locked mid-read).
      _service.setLiveSource(
        buildSnapshot: notifier.buildWebSnapshot,
        onRequestDownload: notifier.webRequestDownload,
      );
      // Screen-off keep-alive (WebKeepaliveService): the notification
      // shows the address other devices should open. Best-effort —
      // failures are logged inside the bridge; the server runs either
      // way. An empty text keeps just the "zlibx" title (no detected
      // address is rare, but the CPU/Wi-Fi locks still matter).
      final primary = _selection?.primary;
      final port = _service.port;
      unawaited(
        WebKeepalive.start(
          text: primary == null || port == null
              ? ''
              : lanUrl(primary.address, port),
        ),
      );
      // Battery optimization: aggressive OEM builds kill even the
      // foreground service, so the keep-alive is not bulletproof
      // without the exemption. The moment the user starts serving is
      // exactly when the dialog is meaningful — asking from a bare
      // settings entry would be easy to ignore. Exempted devices and
      // non-Android platforms never see it.
      if (!await WebKeepalive.isIgnoringBatteryOptimization()) {
        unawaited(WebKeepalive.requestIgnoreBatteryOptimization());
      }
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
      // Drop the keep-alive notice and locks even if the stop threw:
      // a dead server with a live "serving at …" notice is a lie.
      unawaited(WebKeepalive.stop());
      if (mounted) {
        setState(() {
          _busy = false;
          _selection = null;
          _clients = null;
        });
      }
    }
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
    refreshLink: t.webPageRefresh,
    packAll: t.webPagePackAll,
    downloadToPhone: t.webPageDownloadToPhone,
    searchHeading: t.webPageSearchHeading,
    zipEmpty: t.webPageZipEmpty,
  );

  /// The app's resolved colors for its current theme (the theme section
  /// can mean Material You dynamic color), handed to the web pages so
  /// they follow the app. Web-triggered theme switches while the server
  /// runs keep the last palette until the screen is opened again.
  WebPalette _webPalette(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String hex(Color c) {
      final argb = c.toARGB32() & 0xFFFFFF;
      return '#${argb.toRadixString(16).padLeft(6, '0')}';
    }

    final dark = theme.brightness == Brightness.dark;
    return WebPalette(
      bg: hex(theme.scaffoldBackgroundColor),
      card: hex(cs.surface),
      text: hex(cs.onSurface),
      muted: hex(cs.onSurfaceVariant),
      line: hex(cs.outlineVariant),
      brand: hex(cs.primary),
      // Hover goes darker on light schemes and lighter on dark ones,
      // matching how the app's own press states resolve.
      brandStrong: hex(
        Color.lerp(cs.primary, dark ? Colors.white : Colors.black, 0.14)!,
      ),
      brandSoft: hex(cs.primaryContainer),
      brandSoftStrong: hex(
        Color.lerp(cs.primaryContainer, cs.primary, 0.25)!,
      ),
      onBrand: hex(cs.onPrimary),
      onSoft: hex(cs.onPrimaryContainer),
      tile: hex(cs.surfaceContainerHighest),
      dark: dark,
    );
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
    final url = lanUrl(primary.address, port);
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

  /// Snapshot counts (frozen at start) plus the snapshot note,
  /// aligned with the rows above it.
  Widget _statsCard(
    AppLocalizations t,
    ColorScheme cs,
    WebSnapshot snapshot,
  ) {
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
          ListTile(
            dense: true,
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
