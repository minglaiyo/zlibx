// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/ui/challenge_solver_page.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
//
// Full-screen fallback page shown when the automatic headless challenge
// solver could not clear DDoS-Guard on its own (e.g. a real human CAPTCHA).
// The page loads the blocked URL in a visible InAppWebView, waits until the
// challenge is gone and the page has fully rendered, stores the captured HTML
// in ChallengeHtmlCache (keyed by request URL) and pops itself. The caller then
// simply retries - the cached HTML is used instead of a doomed Dio request.
//
// zlibx adaptation: class renamed ChallengeSolverScreen to match this
// app's screen naming; title/hint come from the app's own l10n keys
// (`verifying_access` / `verifying_access_hint`).

// Dart imports:
import 'package:zlibx/utils/diagnostics.dart';
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/services/challenge_html_cache.dart';
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';

class ChallengeSolverScreen extends StatefulWidget {
  const ChallengeSolverScreen({super.key, required this.url});

  final String url;

  @override
  State<ChallengeSolverScreen> createState() => _ChallengeSolverScreenState();
}

class _ChallengeSolverScreenState extends State<ChallengeSolverScreen> {
  final AppLogger _logger = AppLogger();
  InAppWebViewController? _controller;
  Timer? _pollTimer;
  bool _done = false;
  double _progress = 0;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_done || !mounted) return;
      final controller = _controller;
      if (controller == null) return;

      try {
        final title = (await controller.getTitle()) ?? '';
        final bodySnippet =
            (await controller.evaluateJavascript(
              source:
                  "document.body ? document.body.innerHTML.slice(0, 3000) : ''",
            ))?.toString() ??
            '';

        if (title.isEmpty && bodySnippet.isEmpty) return;

        if (WebviewChallengeSolver.isChallengePage(
          title: title,
          bodySnippet: bodySnippet,
        )) {
          _logger.debug(
            'Challenge still active (solver page)',
            tag: 'ChallengeSolver',
            metadata: {'title': title},
          );
          return;
        }

        final ready =
            (await controller.evaluateJavascript(
              source: "document.readyState",
            ))?.toString() ??
            '';
        if (ready != 'complete') return;

        // Settle so late XHR content lands in the DOM.
        await Future.delayed(const Duration(milliseconds: 2000));
        if (_done || !mounted) return;

        final html =
            (await controller.evaluateJavascript(
              source: "document.documentElement.outerHTML",
            ))?.toString() ??
            '';
        if (html.isNotEmpty) {
          _done = true;
          ChallengeHtmlCache.store(widget.url, html);
          _logger.info(
            'Solver page captured HTML',
            tag: 'ChallengeSolver',
            metadata: {'url': widget.url, 'length': html.length},
          );
          _pollTimer?.cancel();
          if (mounted) Navigator.pop(context, true);
        }
      } catch (error) {
        logIgnored('challenge_solver_screen', error);
        // webview might be mid-navigation; keep polling
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.verifyingAccess)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.verifyingAccessHint,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_progress < 1)
              LinearProgressIndicator(value: _progress, minHeight: 2),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  supportZoom: false,
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  _startPolling();
                },
                onProgressChanged: (controller, progress) {
                  if (mounted) {
                    setState(() => _progress = progress / 100);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
