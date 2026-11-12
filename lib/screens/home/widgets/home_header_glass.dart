import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// A progressive-blur header: the same graduated frost legado gets from
/// HazeProgressive.verticalGradient(startIntensity = 1, endIntensity = 0).
///
/// Flutter's BackdropFilter has a single uniform sigma, and the naive
/// "BackdropFilter + ShaderMask" recipe isolates the backdrop and shows no
/// blur. [ProgressiveBlur] runs a real fragment shader as the backdrop filter
/// (separable gaussian normalised over this widget's rect), so there is no
/// banding and no hard cut-off. It falls back to a uniform blur on backends
/// without shader filters.
class HomeHeaderGlass extends StatelessWidget {
  const HomeHeaderGlass({
    super.key,
    required this.height,
    required this.blurEnabled,
    required this.surface,
    required this.child,
  });

  final double height;
  final bool blurEnabled;
  final Color surface;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scrim = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[
        surface.withValues(alpha: blurEnabled ? 0.32 : 1),
        surface.withValues(alpha: blurEnabled ? 0.16 : 1),
        surface.withValues(alpha: 0),
      ],
      stops: const <double>[0, 0.58, 1],
    );

    return SizedBox(
      height: height,
      child: Stack(
        children: <Widget>[
          if (blurEnabled)
            const Positioned.fill(
              child: ProgressiveBlur(maxSigma: 18, falloff: 1.1),
            ),
          Positioned.fill(
            child: DecoratedBox(decoration: BoxDecoration(gradient: scrim)),
          ),
          child,
        ],
      ),
    );
  }
}
