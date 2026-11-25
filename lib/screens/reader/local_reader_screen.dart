// The in-app local reader: foliate-js in a WebView, fed by a
// short-lived loopback server ([LocalReaderServer]) that serves the
// book file (see local_reader_server.dart for why loopback beats
// file://). This is the DOWNLOADED-book reader — it reads a file
// already on the device. The online preview reader is the separate
// [ReaderScreen] (/reader, Z-Library's own reader over the network).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/download_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/local_reader_server.dart';
import '../../services/media_store.dart';
import '../../services/reader_formats.dart';
import '../../services/reader_progress.dart';
import '../../utils/app_snack.dart';

/// Arguments for the local reader route.
class LocalReaderArgs {
  /// Real path of the book file on disk (already resolved from a
  /// possible MediaStore content:// URI by the caller).
  final String filePath;

  /// Title shown in the AppBar and the reader page.
  final String title;

  /// Stable per-book key for progress (the download task id).
  final String bookKey;

  const LocalReaderArgs({
    required this.filePath,
    required this.title,
    required this.bookKey,
  });
}

class LocalReaderScreen extends StatefulWidget {
  final LocalReaderArgs args;

  const LocalReaderScreen({super.key, required this.args});

  @override
  State<LocalReaderScreen> createState() => _LocalReaderScreenState();
}

class _LocalReaderScreenState extends State<LocalReaderScreen> {
  LocalReaderServer? _server;
  Uri? _url;
  String? _error;
  bool _pageLoading = true;
  InAppWebViewController? _controller;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final savedCfi = ReaderProgressStore.readCfi(widget.args.bookKey);
    final server = LocalReaderServer(
      filePath: widget.args.filePath,
      title: widget.args.title,
      bookKey: widget.args.bookKey,
      savedCfi: savedCfi,
    );
    try {
      final url = await server.start();
      if (!mounted) {
        await server.stop();
        return;
      }
      setState(() {
        _server = server;
        _url = url;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'server failed');
    }
  }

  @override
  void dispose() {
    unawaited(_server?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.args.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: l.refresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: _error != null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '阅读器打不开，请稍后再试',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _url == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    // Everything comes over loopback HTTP; no file
                    // access is needed (and file:// is exactly what
                    // the loopback server exists to avoid).
                    allowFileAccess: false,
                    allowContentAccess: false,
                    useWideViewPort: true,
                    loadWithOverviewMode: true,
                    supportZoom: true,
                    builtInZoomControls: true,
                    displayZoomControls: false,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    algorithmicDarkeningAllowed: false,
                  ),
                  onWebViewCreated: (controller) async {
                    _controller = controller;
                    // Register before the page loads: the reader page
                    // calls this on every relocate.
                    await controller.addJavaScriptHandler(
                      handlerName: 'zlibxReaderProgress',
                      callback: (args) async {
                        if (args.length >= 2 &&
                            args[0] is String &&
                            (args[0] as String).isNotEmpty) {
                          final fraction = args[1] is num
                              ? (args[1] as num).toDouble()
                              : 0.0;
                          await ReaderProgressStore.save(
                            widget.args.bookKey,
                            args[0] as String,
                            fraction,
                          );
                        }
                        return null;
                      },
                    );
                    await controller.loadUrl(
                      urlRequest: URLRequest(url: WebUri.uri(_url!)),
                    );
                  },
                  shouldOverrideUrlLoading:
                      (controller, navigationAction) async {
                    final uri = navigationAction.request.url;
                    // The reader page only ever loads its own
                    // loopback origin (/assets, /book). Anything else
                    // — including the book's own links — stays out.
                    if (uri != null &&
                        uri.scheme == 'http' &&
                        uri.host == '127.0.0.1') {
                      return NavigationActionPolicy.ALLOW;
                    }
                    return NavigationActionPolicy.CANCEL;
                  },
                  onLoadStart: (_, __) {
                    if (mounted) setState(() => _pageLoading = true);
                  },
                  onLoadStop: (_, __) {
                    if (mounted) setState(() => _pageLoading = false);
                  },
                ),
                if (_pageLoading)
                  const LinearProgressIndicator(minHeight: 2),
              ],
            ),
    );
  }
}

/// Open the in-app reader for a completed download task.
///
/// Returns true when the reader was opened. Returns false when the
/// book cannot be read locally (missing file, or a format foliate
/// cannot open such as PDF) — the caller then falls back to opening
/// the file in the external viewer. A missing file is marked on the
/// task, same as the download list's own open-file path.
Future<bool> openLocalReaderForTask(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  if (!isReadableExtension(task.book.extension)) return false;
  final path = task.filePath;
  if (path == null) return false;
  if (!await MediaStoreFiles.exists(path)) {
    ref.read(downloadProvider.notifier).markMissingFile(task.id);
    if (context.mounted) {
      showAppSnack(
        context,
        AppLocalizations.of(context)!.downloadFileMissing,
      );
    }
    return false;
  }
  // MediaStore-published downloads live at a content:// URI, which
  // the loopback server cannot read — resolve to a real path first
  // (shareablePath copies to the app cache when there is no direct
  // real path).
  final realPath = MediaStoreFiles.isContentUri(path)
      ? (await MediaStoreFiles.realPath(path) ??
            await MediaStoreFiles.shareablePath(path))
      : path;
  if (realPath == null || realPath.isEmpty) return false;
  if (!context.mounted) return false;
  unawaited(
    AppRoutes.openLocalReader(
      context,
      LocalReaderArgs(
        filePath: realPath,
        title: task.book.title,
        bookKey: task.id,
      ),
    ),
  );
  return true;
}
