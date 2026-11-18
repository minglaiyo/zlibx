import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_metrics.dart';
import '../theme/motion.dart';


/// Lightweight M3 Expressive-inspired morphing indicator for unknown durations.
/// Determinate transfers continue to use progress indicators with real values.
/// (Ported from the c001apk fork.)
class ExpressiveLoadingIndicator extends StatefulWidget {
  const ExpressiveLoadingIndicator({
    super.key,
    this.size = 40,
    this.color,
    this.value,
  });

  final double size;

  /// Overrides the theme primary color (e.g. white on a filled button).
  final Color? color;

  /// Determinate progress 0..1; when set, the blob holds the matching phase
  /// instead of looping. Null (the default) loops forever.
  final double? value;

  @override
  State<ExpressiveLoadingIndicator> createState() =>
      _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: AppMotion.shimmer,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ExpressiveLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _syncAnimation();
  }

  void _syncAnimation() {
    final value = widget.value;
    if (value != null) {
      _controller.stop();
      _controller.value = value.clamp(0.0, 1.0);
    } else if (context.disableAnimations ||
        !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: AppLocalizations.of(context)!.loading,
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _MorphingShapePainter(
            animation: _controller,
            color: widget.color ?? Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ),
  );
}

class _MorphingShapePainter extends CustomPainter {
  _MorphingShapePainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  static const _lobes = [4, 6, 5, 3, 8, 4, 6];

  @override
  void paint(Canvas canvas, Size size) {
    final phase = animation.value * _lobes.length;
    final index = phase.floor() % _lobes.length;
    final blend = MotionCurves.loop.transform(phase - phase.floor());
    final radius = size.shortestSide * 0.43;
    final path = Path();
    for (var i = 0; i <= 120; i++) {
      final angle = i / 120 * math.pi * 2;
      final a = math.cos(angle * _lobes[index]);
      final b = math.cos(angle * _lobes[(index + 1) % _lobes.length]);
      final r = radius * (0.84 + 0.16 * (a + (b - a) * blend));
      final rotation = angle + animation.value * math.pi * 4;
      final x = size.width / 2 + r * math.cos(rotation);
      final y = size.height / 2 + r * math.sin(rotation);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MorphingShapePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animation != animation;
}
