import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// One item of [LiquidSegmentedControl].
@immutable
class LiquidSegment {
  const LiquidSegment({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// A small draggable segmented control with the same liquid feel as the
/// bottom navigation bar: one lens slides between segments, follows the
/// finger, clicks at each crossing and springs to the nearest segment on
/// release. Replaces three independently AnimatedContainer segments, which
/// caused the source switcher to flicker.
class LiquidSegmentedControl extends StatefulWidget {
  const LiquidSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.glass = true,
    this.height = 40,
  });

  final List<LiquidSegment> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool glass;
  final double height;

  @override
  State<LiquidSegmentedControl> createState() => _LiquidSegmentedControlState();
}

class _LiquidSegmentedControlState extends State<LiquidSegmentedControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  final ValueNotifier<double> _press = ValueNotifier<double>(0);
  late final Listenable _repaint = Listenable.merge(<Listenable>[
    _progress,
    _press,
  ]);

  bool _dragging = false;
  int _pressedIndex = -1;

  static const double _pad = 4;
  static const double _gap = 6;

  int get _count => widget.segments.length;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController.unbounded(
      vsync: this,
      value: widget.selectedIndex.toDouble(),
    );
  }

  @override
  void didUpdateWidget(covariant LiquidSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.selectedIndex != widget.selectedIndex) {
      _springTo(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _press.dispose();
    super.dispose();
  }

  void _springTo(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = index.toDouble();
      return;
    }
    _progress.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 500, damping: 38),
        _progress.value,
        index.toDouble(),
        0,
      ),
    );
  }

  double _segmentWidth(Size size) => (size.width - _pad * 2) / _count;

  int _indexAt(Size size, double dx) {
    final segment = _segmentWidth(size);
    if (segment <= 0) return 0;
    return ((dx - _pad) / segment).floor().clamp(0, _count - 1);
  }

  double _continuousAt(Size size, double dx) {
    final segment = _segmentWidth(size);
    if (segment <= 0) return 0;
    return ((dx - _pad) / segment - 0.5)
        .clamp(-0.15, (_count - 1) + 0.15)
        .toDouble();
  }

  void _select(int index, Size size) {
    if (index != widget.selectedIndex) widget.onChanged(index);
    _springTo(index);
  }

  void _handleTapDown(TapDownDetails details, Size size) {
    _pressedIndex = _indexAt(size, details.localPosition.dx);
    _press.value = 1;
  }

  void _handleTapUp(TapUpDetails details, Size size) {
    _press.value = 0;
    final index = _indexAt(size, details.localPosition.dx);
    _pressedIndex = -1;
    _select(index, size);
  }

  void _handleTapCancel() {
    _press.value = 0;
    _pressedIndex = -1;
  }

  void _handleDragStart(DragStartDetails details, Size size) {
    _dragging = true;
    _press.value = 1;
    _pressedIndex = _indexAt(size, details.localPosition.dx);
    _progress.value = _continuousAt(size, details.localPosition.dx);
    HapticFeedback.selectionClick();
  }

  void _handleDragUpdate(DragUpdateDetails details, Size size) {
    if (!_dragging) return;
    final next = _continuousAt(size, details.localPosition.dx);
    if ((next - _progress.value).abs() < 0.0005) return;
    _progress.value = next;
    final index = next.round().clamp(0, _count - 1);
    if (index != _pressedIndex) {
      _pressedIndex = index;
      HapticFeedback.selectionClick();
    }
  }

  void _handleDragEnd() {
    if (!_dragging) return;
    _dragging = false;
    _press.value = 0;
    _pressedIndex = -1;
    final target = _progress.value.round().clamp(0, _count - 1);
    _springTo(target);
    if (target != widget.selectedIndex) widget.onChanged(target);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          return DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(widget.height / 2),
            ),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SegmentLensPainter(
                        repaint: _repaint,
                        progress: _progress,
                        press: _press,
                        count: _count,
                        pad: _pad,
                        gap: _gap,
                        glass: widget.glass,
                        accent: cs.primary,
                        container: cs.primaryContainer,
                        isDark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: _buildRow(size, cs.onSurfaceVariant),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _progress,
                      child: ExcludeSemantics(
                        child: _buildRow(size, cs.primary),
                      ),
                      builder: (context, child) {
                        final lens = _SegmentLensGeometry.resolve(
                          size,
                          progress: _progress.value,
                          press: _press.value,
                          count: _count,
                          pad: _pad,
                          gap: _gap,
                        );
                        return ClipPath(
                          clipper: _SegmentBandClipper(
                            Rect.fromLTRB(
                              lens.outerRect.left,
                              0,
                              lens.outerRect.right,
                              size.height,
                            ),
                          ),
                          child: child,
                        );
                      },
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => _handleTapDown(details, size),
                    onTapUp: (details) => _handleTapUp(details, size),
                    onTapCancel: _handleTapCancel,
                    onHorizontalDragStart: (details) =>
                        _handleDragStart(details, size),
                    onHorizontalDragUpdate: (details) =>
                        _handleDragUpdate(details, size),
                    onHorizontalDragEnd: (_) => _handleDragEnd(),
                    onHorizontalDragCancel: _handleDragEnd,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRow(Size size, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _pad),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _count; i++)
            Expanded(
              child: SizedBox(
                height: size.height,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(widget.segments[i].icon, size: 16, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.segments[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: i == widget.selectedIndex
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentLensGeometry {
  const _SegmentLensGeometry._();

  static RRect resolve(
    Size size, {
    required double progress,
    required double press,
    required int count,
    required double pad,
    required double gap,
  }) {
    final segment = (size.width - pad * 2) / count;
    final half = segment / 2;
    final centerX = (pad + (progress + 0.5) * segment)
        .clamp(pad + half, size.width - pad - half)
        .toDouble();
    final width = math.max(20.0, (segment - gap) * (1 + press * 0.02));
    final height = (size.height - 8) * (1 + press * 0.03);
    final rect = Rect.fromCenter(
      center: Offset(centerX, size.height / 2),
      width: width,
      height: height,
    );
    return RRect.fromRectAndRadius(rect, Radius.circular(height / 2));
  }
}

class _SegmentBandClipper extends CustomClipper<Path> {
  const _SegmentBandClipper(this.rect);

  final Rect rect;

  @override
  Path getClip(Size size) => Path()..addRect(rect);

  @override
  bool shouldReclip(covariant _SegmentBandClipper oldClipper) =>
      oldClipper.rect != rect;
}

class _SegmentLensPainter extends CustomPainter {
  _SegmentLensPainter({
    required Listenable repaint,
    required this.progress,
    required this.press,
    required this.count,
    required this.pad,
    required this.gap,
    required this.glass,
    required this.accent,
    required this.container,
    required this.isDark,
  }) : super(repaint: repaint);

  final Animation<double> progress;
  final ValueNotifier<double> press;
  final int count;
  final double pad;
  final double gap;
  final bool glass;
  final Color accent;
  final Color container;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = _SegmentLensGeometry.resolve(
      size,
      progress: progress.value,
      press: press.value,
      count: count,
      pad: pad,
      gap: gap,
    );
    if (!glass) {
      canvas.drawRRect(
        rrect,
        Paint()..color = container.withValues(alpha: 0.92),
      );
      return;
    }
    final rect = rrect.outerRect;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            container.withValues(alpha: isDark ? 0.62 : 0.78),
            accent.withValues(alpha: isDark ? 0.12 : 0.08),
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.06 : 0.12),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.24 : 0.5),
            Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _SegmentLensPainter old) => false;
}
