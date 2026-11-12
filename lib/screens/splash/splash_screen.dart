import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/domain_provider.dart';
import '../../providers/speed_test_provider.dart';
import '../../routes/app_routes.dart';
import '../../utils/app_log.dart';
import '../../widgets/domain_selector.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  String _statusText = '';
  bool _networkOk = false;

  late final AnimationController _entrance;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _fade = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0, 0.8, curve: Curves.easeOut),
    );
    _scale = Tween<double>(
      begin: 0.96,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _entrance.forward();

    Future.microtask(() => ref.read(speedTestProvider.notifier).runTest());
    _initialize();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() => _statusText = AppLocalizations.of(context)!.checkingNetwork);
    _networkOk = await _checkNetwork();

    if (!mounted) return;
    if (!_networkOk) {
      setState(
        () => _statusText = AppLocalizations.of(
          context,
        )!.networkUnavailableRetrying,
      );
      await Future.delayed(const Duration(seconds: 2));
      _networkOk = await _checkNetwork();
    }

    while (!_networkOk && mounted) {
      final action = await _showLineUnavailableDialog();
      if (!mounted) return;
      if (action == _LineAction.proceed || action == _LineAction.skip) break;
      setState(
        () => _statusText = AppLocalizations.of(context)!.checkingNetwork,
      );
      _networkOk = await _checkNetwork();
    }

    if (!mounted) return;
    setState(() => _statusText = AppLocalizations.of(context)!.loading);
    await _waitForAuth();
  }

  Future<_LineAction?> _showLineUnavailableDialog() async {
    final cs = Theme.of(context).colorScheme;
    return showDialog<_LineAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.lineUnavailable),
        content: Text(AppLocalizations.of(context)!.splashLineUnreachable),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LineAction.skip),
            child: Text(AppLocalizations.of(context)!.skip),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LineAction.proceed),
            child: Text(AppLocalizations.of(context)!.continueAnyway),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LineAction.retry),
            child: Text(AppLocalizations.of(context)!.searchRetry),
          ),
          FilledButton(
            onPressed: () async {
              await showDialog(
                context: ctx,
                builder: (_) => const DomainSelectionDialog(),
              );
              if (ctx.mounted) Navigator.pop(ctx, _LineAction.retry);
            },
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
            child: Text(AppLocalizations.of(context)!.switchLine),
          ),
        ],
      ),
    );
  }

  Future<bool> _checkNetwork() async {
    try {
      final domain = ref.read(domainProvider);
      final uri = Uri.parse('https://$domain/eapi/info/languages');

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      try {
        final request = await client.getUrl(uri);
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        return response.statusCode >= 200 && response.statusCode < 300;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLog.report(
        'Network check failed: ${e.runtimeType}',
        tag: 'splash_screen',
      );
      return false;
    }
  }

  void _goHome() {
    if (!mounted) return;
    AppRoutes.splashToHome(context);
  }

  void _goLogin() {
    if (!mounted) return;
    AppRoutes.splashToLogin(context);
  }

  Future<void> _waitForAuth() async {
    await ref.read(authProvider.notifier).ready;
    if (!mounted) return;
    if (ref.read(authProvider).isAuthenticated) {
      _goHome();
    } else {
      _goLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = AppLocalizations.of(context)!;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 92,
                        height: 92,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Icon(
                          Icons.auto_stories_rounded,
                          size: 46,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'zlibx',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        t.yourOpenLibrary,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 40 + bottomInset,
              child: FadeTransition(
                opacity: _fade,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: cs.primary,
                        backgroundColor: cs.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 14),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _statusText.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              _statusText,
                              key: ValueKey<String>(_statusText),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version;
                    if (version == null) return const SizedBox.shrink();
                    return Text(
                      'v$version',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                        letterSpacing: 0.3,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _LineAction { retry, proceed, skip }
