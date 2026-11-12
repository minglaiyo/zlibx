import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io';
import '../../l10n/generated/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/domain_provider.dart';
import '../../providers/speed_test_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_log.dart';
import '../../widgets/domain_selector.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  String _statusText = '';
  bool _networkOk = false;

  // ── Animation Controllers ──
  late final AnimationController _logoController;
  late final AnimationController _pulseController;
  late final AnimationController _ringController;
  late final AnimationController _contentController;

  // ── Animations ──
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _titleSlide;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _ringRotation;
  late final Animation<double> _bottomOpacity;

  @override
  void initState() {
    super.initState();

    // Logo entrance: scale from 0.3→1.0 + fade in
    _logoController = AnimationController(
      vsync: this,
      duration: AppMotion.slowest,
    );
    _logoScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    // Content entrance (title + status): staggered after logo
    _contentController = AnimationController(
      vsync: this,
      duration: AppMotion.verySlow,
    );
    _titleSlide = Tween<double>(begin: 20.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _contentController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );
    _bottomOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentController,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );

    // Pulse glow behind logo: infinite breathing
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Ring spinner: replaces CircularProgressIndicator
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _ringRotation = Tween<double>(begin: 0.0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.linear),
    );

    // Start animation sequence
    _startAnimations();

    // Fire-and-forget: start background speed test for all domains
    Future.microtask(() => ref.read(speedTestProvider.notifier).runTest());
    _initialize();
  }

  void _startAnimations() async {
    // Slight delay for smoother feel
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    unawaited(_logoController.forward());

    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    unawaited(_contentController.forward());
  }

  @override
  void dispose() {
    _logoController.dispose();
    _pulseController.dispose();
    _ringController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Step 1: Check network on the current line
    setState(() => _statusText = AppLocalizations.of(context)!.checkingNetwork);
    _networkOk = await _checkNetwork();

    if (!mounted) return;
    if (!_networkOk) {
      setState(() => _statusText = AppLocalizations.of(context)!.networkUnavailableRetrying);
      await Future.delayed(const Duration(seconds: 2));
      _networkOk = await _checkNetwork();
    }

    // Still unreachable — prompt user to switch line before continuing.
    while (!_networkOk && mounted) {
      final action = await _showLineUnavailableDialog();
      if (!mounted) return;
      if (action == _LineAction.proceed || action == _LineAction.skip) break;
      setState(() => _statusText = AppLocalizations.of(context)!.checkingNetwork);
      _networkOk = await _checkNetwork();
    }

    // Step 2: Wait for auth state
    if (!mounted) return;
    setState(
      () => _statusText = AppLocalizations.of(context)!.loading,
    );
    await _waitForAuth();
  }

  Future<_LineAction?> _showLineUnavailableDialog() async {
    final cs = Theme.of(context).colorScheme;
    return showDialog<_LineAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.lineUnavailable),
        content: Text(
          AppLocalizations.of(context)!.splashLineUnreachable,
        ),
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
          ElevatedButton(
            onPressed: () async {
              await showDialog(
                context: ctx,
                builder: (_) => const DomainSelectionDialog(),
              );
              if (ctx.mounted) Navigator.pop(ctx, _LineAction.retry);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: Colors.white,
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
      // Use API endpoint for testing (same as domain selector)
      final uri = Uri.parse('https://$domain/eapi/info/languages');
      
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      
      try {
        final request = await client.getUrl(uri);
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        
        // Headers are enough (same rule as the speed test): a healthy
        // mirror answers this endpoint 2xx. The body is never read, so a
        // hostile or broken mirror cannot make us buffer an unbounded
        // response, and a non-2xx page no longer counts as success.
        return response.statusCode >= 200 && response.statusCode < 300;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      // Network-layer exception text can carry URLs or response
      // fragments: log the type only.
      AppLog.report(
        'Network check failed: ${e.runtimeType}',
        tag: 'splash_screen',
      );
      return false;
    }
  }

  /// Splash exits with a fade, not a slide: the splash is full dark-green
  /// while home/login are full white, so a slide reads as a flash. The
  /// 300 ms fade itself lives in [AppRoutes.splashToHome].
  void _goHome() {
    if (!mounted) return;
    AppRoutes.splashToHome(context);
  }

  void _goLogin() {
    if (!mounted) return;
    AppRoutes.splashToLogin(context);
  }

  Future<void> _waitForAuth() async {
    // Await the auth init directly: the old 500ms poll capped the wait
    // at 10s, so a logged-in user on a slow line was misrouted to login.
    // `ready` settles on every _init path (success / auth failure /
    // line error); the wait is bounded by the API client's own timeouts.
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
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(cs.primary, Colors.black, 0.35)!,
              cs.primary,  // Core primary
              cs.primaryContainer,
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // ── Decorative floating circles ──
            _buildBackgroundDecor(),

            // ── Main content ──
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 3),

                  // ── Pulsing Glow + Animated Logo ──
                  AnimatedBuilder(
                    animation: Listenable.merge([_logoController, _pulseController]),
                    builder: (context, child) {
                      return Opacity(
                        opacity: _logoOpacity.value,
                        child: Transform.scale(
                          scale: _logoScale.value,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Outer glow pulse
                              Transform.scale(
                                scale: _pulseAnimation.value,
                                child: Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        Colors.white.withValues(alpha:0.12),
                                        Colors.white.withValues(alpha:0.04),
                                        Colors.white.withValues(alpha:0.0),
                                      ],
                                      stops: const [0.0, 0.6, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                              // Icon container
                              Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha:0.15),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha:0.25),
                                    width: 1.5,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.auto_stories_rounded,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 28),

                  // ── Title with slide-up animation ──
                  AnimatedBuilder(
                    animation: _contentController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _titleOpacity.value,
                        child: Transform.translate(
                          offset: Offset(0, _titleSlide.value),
                          child: Column(
                            children: [
                              Text(
                                'zlibx',
                                style: Theme.of(context)
                                    .textTheme
                                    .displayLarge
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2.0,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                AppLocalizations.of(context)!
                                    .yourOpenLibrary,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha:0.6),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 48),

                  // ── Custom spinning ring loader ──
                  AnimatedBuilder(
                    animation: Listenable.merge([_contentController, _ringController]),
                    builder: (context, child) {
                      return Opacity(
                        opacity: _bottomOpacity.value,
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: CustomPaint(
                            painter: _RingSpinnerPainter(
                              rotation: _ringRotation.value,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 20),

                  // ── Status indicator with animated dot ──
                  AnimatedBuilder(
                    animation: _contentController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _bottomOpacity.value,
                        child: child,
                      );
                    },
                    child: AnimatedSwitcher(
                      duration: AppMotion.slow,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.3),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: Row(
                        key: ValueKey(_statusText),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Animated status dot
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: _networkOk
                                  ? const Color(0xFF4ADE80)
                                  : Colors.white.withValues(alpha:0.5),
                              shape: BoxShape.circle,
                              boxShadow: _networkOk
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF4ADE80)
                                            .withValues(alpha:0.6),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _statusText,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha:0.7),
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(flex: 2),

                  // ── Bottom version text ──
                  AnimatedBuilder(
                    animation: _contentController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _bottomOpacity.value * 0.5,
                        child: child,
                      );
                    },
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom + 24,
                      ),
                      child: FutureBuilder<PackageInfo>(
                        future: PackageInfo.fromPlatform(),
                        builder: (context, snapshot) {
                          final version = snapshot.data?.version ?? '...';
                          return Text(
                            'v$version',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha:0.4),
                              fontSize: 11,
                              letterSpacing: 0.5,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Subtle decorative circles on the background
  Widget _buildBackgroundDecor() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final pulse = _pulseAnimation.value;
        return Stack(
          children: [
            Positioned(
              top: -60,
              right: -40,
              child: Transform.scale(
                scale: pulse * 0.95,
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha:0.03),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              left: -60,
              child: Transform.scale(
                scale: 2.0 - pulse * 0.9,
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha:0.025),
                  ),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).size.height * 0.35,
              left: -30,
              child: Transform.scale(
                scale: pulse,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha:0.02),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _LineAction { retry, proceed, skip }

// ════════════════════════════════════════════════════════════
//  Custom Ring Spinner — elegant arc spinner
// ════════════════════════════════════════════════════════════
class _RingSpinnerPainter extends CustomPainter {
  final double rotation;
  final Color color;

  _RingSpinnerPainter({required this.rotation, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // Background ring (very faint)
    final bgPaint = Paint()
      ..color = color.withValues(alpha:0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    // Spinning arc with gradient opacity
    final arcPaint = Paint()
      ..color = color.withValues(alpha:0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);

    // Primary arc (120°)
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0,
      math.pi * 0.67,
      false,
      arcPaint,
    );

    // Secondary arc (shorter, opposite side, dimmer)
    final arcPaint2 = Paint()
      ..color = color.withValues(alpha:0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi * 0.35,
      false,
      arcPaint2,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RingSpinnerPainter oldDelegate) {
    return oldDelegate.rotation != rotation;
  }
}
