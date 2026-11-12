import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/nav_label_mode.dart';

/// One destination of [LiquidNavBar].
@immutable
class LiquidNavDestination {
  const LiquidNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Floating "liquid glass" bottom navigation bar.
///
/// The visual model follows legado's compact M3/Expressive tab item and
/// NeriPlayer's draggable glass tabs:
///
/// * a 64dp frosted capsule floating over the content;
/// * a compact lens (about 64x32) behind the active **icon** — not a
///   full-height pill — so the label stays clear and the bar reads like a
///   normal M3 navigation bar with a glass thumb;
/// * press and drag anywhere on the bar: the lens jumps to the icon under
///   the finger, follows it with velocity squash/stretch, clicks at every
///   icon it crosses, and snaps to the nearest one on release;
/// * icons and labels are drawn twice, the accent copy clipped to a vertical
///   band around the lens, so the colour sweeps through the row as the lens
///   moves;
/// * the pressed icon springs to 1.18x, the selected icon to 1.06x.
///
/// The widget has no animation-package dependency: just a ticker, a spring
/// simulation, [BackdropFilter] and [CustomPainter].
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.pageController,
    this.visible = true,
    this.blurEnabled = true,
    this.floating = true,
    this.refractionEnabled = false,
    this.labelMode = NavLabelMode.always,
  }) : assert(destinations.length > 1, 'needs at least two destinations');

  final List<LiquidNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Keeps the lens in sync while the pages swipe. Press-dragging the bar
  /// temporarily owns the lens and snaps it on release.
  final PageController? pageController;

  /// When false the bar slides down, fades and shrinks away (hide-on-scroll).
  final bool visible;

  /// When false the glass falls back to an opaque surface (settings switch).
  final bool blurEnabled;

  /// When false the bar docks to the bottom edge as a full-width sheet.
  final bool floating;

  /// Extra lens pass: a second backdrop blur under the lens plus a thick
  /// refracting rim. Motion is identical when off; only the lens rendering is
  /// skipped. Off by default, like legado's glass switch.
  final bool refractionEnabled;

  /// Always show labels, show only the selected label, or hide labels
  /// entirely (legado's NavigationBarDisplayMode).
  final NavLabelMode labelMode;

  /// Height of the bar itself, excluding the system inset.
  static const double barHeight = 64;

  /// Miuix/legado proportion: 64-high bar and 56-high indicator are both
  /// pills (CircleShape), so the bar's 32 radius wraps the lens's 28 with a
  /// uniform 4dp rim and the two ends share the same stadium shape.
  static const double barRadius = barHeight / 2;

  /// Horizontal distance from the screen edge for the floating capsule.
  static const double horizontalMargin = 20;

  /// Space a scrollable should reserve at the bottom so its last row can
  /// scroll clear of the bar (bar + margin + breathing room).
  static double bottomClearance(
    BuildContext context, {
    required bool floating,
  }) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    return barHeight + (floating ? 8 + inset + 16 : inset + 12);
  }

  @override
  State<LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends State<LiquidNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _progress;
  final ValueNotifier<double> _stretch = ValueNotifier<double>(0);
  final ValueNotifier<double> _press = ValueNotifier<double>(0);
  late final Listenable _repaint = Listenable.merge(<Listenable>[
    _progress,
    _stretch,
    _press,
  ]);
  late final Ticker _ticker;

  double _lastTickValue = 0;
  double _velocity = 0;
  Duration _lastTick = Duration.zero;
  int _visualIndex = 0;
  int _pressedIndex = -1;
  bool _dragging = false;
  bool _ignorePage = false;
  Timer? _snapTimer;
  Size? _barSize;

  @override
  void initState() {
    super.initState();
    _visualIndex = widget.selectedIndex;
    _progress = AnimationController.unbounded(
      vsync: this,
      value: widget.selectedIndex.toDouble(),
    );
    _progress.addListener(_onProgressChanged);
    _lastTickValue = _progress.value;
    _ticker = createTicker(_onTick);
    widget.pageController?.addListener(_onPagePositionChanged);
  }

  @override
  void didUpdateWidget(covariant LiquidNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_onPagePositionChanged);
      widget.pageController?.addListener(_onPagePositionChanged);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        widget.pageController == null) {
      _springTo(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    widget.pageController?.removeListener(_onPagePositionChanged);
    _ticker.dispose();
    _progress.dispose();
    _stretch.dispose();
    _press.dispose();
    super.dispose();
  }

  int get _count => widget.destinations.length;

  bool get _showLabels => widget.labelMode != NavLabelMode.never;

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1000000.0;
    _lastTick = elapsed;
    if (dt <= 0) return;
    final value = _progress.value;
    final instant = ((value - _lastTickValue) / dt).clamp(-10.0, 10.0);
    _lastTickValue = value;
    _velocity = _velocity * 0.72 + instant * 0.28;
    _stretch.value = (_velocity * 0.026).clamp(-0.12, 0.12);
    if (!_progress.isAnimating && _velocity.abs() < 0.008) {
      _velocity = 0;
      _stretch.value = 0;
      _lastTick = Duration.zero;
      _ticker.stop();
    }
  }

  void _ensureTicker() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _lastTickValue = _progress.value;
    _velocity = 0;
    _ticker.start();
  }

  void _onProgressChanged() {
    _ensureTicker();
    final index = _progress.value.round().clamp(0, _count - 1);
    if (index == _visualIndex) return;
    _visualIndex = index;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _onPagePositionChanged() {
    if (_dragging || _ignorePage) return;
    final controller = widget.pageController;
    if (controller == null || !controller.hasClients) return;
    final page = controller.page;
    if (page == null) return;
    final clamped = page.clamp(0.0, (_count - 1).toDouble());
    if ((clamped - _progress.value).abs() <= 0.0005) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _progress.value = clamped;
      });
    } else {
      _progress.value = clamped;
    }
  }

  void _springTo(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = index.toDouble();
      return;
    }
    _ensureTicker();
    _progress.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 34),
        _progress.value,
        index.toDouble(),
        (_velocity * 2).clamp(-6.0, 6.0),
      ),
    );
  }

  void _syncToPage() {
    final controller = widget.pageController;
    if (controller == null || !controller.hasClients) return;
    final page = controller.page;
    if (page == null) return;
    _progress.value = page.clamp(0.0, (_count - 1).toDouble());
  }

  double _continuousIndex(double x) {
    final size = _barSize;
    if (size == null) return _progress.value;
    final tabWidth = _LensGeometry.tabWidth(size, _count);
    if (tabWidth <= 0) return 0;
    return ((x - _LensGeometry.padH) / tabWidth - 0.5)
        .clamp(-0.15, (_count - 1) + 0.15)
        .toDouble();
  }

  int _indexFromX(double x) => _continuousIndex(x).round().clamp(0, _count - 1);

  void _setPressed(int index) {
    if (_pressedIndex == index) return;
    setState(() => _pressedIndex = index);
    _press.value = index >= 0 ? 1 : 0;
  }

  void _clearPress() => _setPressed(-1);

  void _select(int index) {
    _snapTimer?.cancel();
    _ignorePage = false;
    final sameTab = index == widget.selectedIndex;
    if (sameTab) {
      HapticFeedback.lightImpact();
      widget.onSelected(index);
      return;
    }
    HapticFeedback.selectionClick();
    widget.onSelected(index);
    if (widget.pageController == null) _springTo(index);
  }

  void _handleTapDown(TapDownDetails details) {
    _setPressed(_indexFromX(details.localPosition.dx));
  }

  void _handleTapUp(TapUpDetails details) {
    final index = _indexFromX(details.localPosition.dx);
    _clearPress();
    _select(index);
  }

  void _handleTapCancel() => _clearPress();

  void _handleDragStart(DragStartDetails details) {
    _snapTimer?.cancel();
    final index = _indexFromX(details.localPosition.dx);
    setState(() {
      _dragging = true;
      _ignorePage = true;
      _pressedIndex = index;
      _visualIndex = index;
    });
    _press.value = 1;
    _progress.value = index.toDouble();
    _ensureTicker();
    HapticFeedback.selectionClick();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final next = _continuousIndex(details.localPosition.dx);
    if ((next - _progress.value).abs() > 0.0005) {
      _progress.value = next;
    }
    final index = next.round().clamp(0, _count - 1);
    if (index != _pressedIndex) {
      setState(() => _pressedIndex = index);
      HapticFeedback.selectionClick();
    }
  }

  void _handleDragEnd() {
    if (!_dragging) return;
    final target = _progress.value.round().clamp(0, _count - 1);
    setState(() {
      _dragging = false;
      _pressedIndex = -1;
    });
    _press.value = 0;
    _springTo(target);
    if (target == widget.selectedIndex) {
      _ignorePage = false;
      return;
    }
    widget.onSelected(target);
    _ignorePage = true;
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _ignorePage = false;
      _syncToPage();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final radius = widget.floating
        ? const BorderRadius.all(Radius.circular(LiquidNavBar.barRadius))
        : BorderRadius.zero;
    final visible = widget.visible;

    final bar = Container(
      margin: widget.floating
          ? EdgeInsets.fromLTRB(
              LiquidNavBar.horizontalMargin,
              0,
              LiquidNavBar.horizontalMargin,
              8 + inset,
            )
          : EdgeInsets.zero,
      child: _GlassSurface(
        radius: radius,
        blurEnabled: widget.blurEnabled,
        floating: widget.floating,
        child: SizedBox(
          height: LiquidNavBar.barHeight + (widget.floating ? 0 : inset),
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: LiquidNavBar.barHeight,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.35,
                  child: _buildBarContent(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (reduceMotion) {
      return IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: Opacity(opacity: visible ? 1 : 0, child: bar),
        ),
      );
    }

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 1.1),
        duration: duration,
        curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
        child: AnimatedScale(
          scale: visible ? 1 : 0.94,
          alignment: Alignment.bottomCenter,
          duration: duration,
          curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: duration,
            child: bar,
          ),
        ),
      ),
    );
  }

  Widget _buildBarContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactive = cs.onSurfaceVariant;
    final active = cs.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, LiquidNavBar.barHeight);
        _barSize = size;
        return Stack(
          children: <Widget>[
            if (widget.refractionEnabled)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _repaint,
                    builder: (context, child) {
                      final rrect = _LensGeometry.resolve(
                        size,
                        progress: _progress.value,
                        stretch: _stretch.value,
                        press: _press.value,
                        count: _count,
                      );
                      return ClipPath(
                        clipper: _LensClipper(rrect),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: ColoredBox(
                            color: Colors.white.withValues(
                              alpha: isDark ? 0.02 : 0.04,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SelectionPainter(
                    repaint: _repaint,
                    progress: _progress,
                    stretch: _stretch,
                    press: _press,
                    count: _count,
                    glass: widget.refractionEnabled,
                    accent: active,
                    container: cs.primaryContainer,
                    isDark: isDark,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ExcludeSemantics(child: _buildRow(color: inactive)),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _repaint,
                  child: ExcludeSemantics(child: _buildRow(color: active)),
                  builder: (context, child) {
                    final band = _LensGeometry.band(
                      size,
                      _progress.value,
                      _count,
                    );
                    return ClipPath(clipper: _BandClipper(band), child: child);
                  },
                ),
              ),
            ),
            if (widget.refractionEnabled)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _SheenPainter(
                      repaint: _repaint,
                      progress: _progress,
                      stretch: _stretch,
                      press: _press,
                      count: _count,

                      isDark: isDark,
                    ),
                  ),
                ),
              ),
            if (widget.refractionEnabled)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _LensPainter(
                      repaint: _repaint,
                      progress: _progress,
                      stretch: _stretch,
                      press: _press,
                      count: _count,

                      isDark: isDark,
                    ),
                  ),
                ),
              ),
            Positioned.fill(child: _buildTargets()),
            // One pointer handler owns the whole bar: a tap selects, a
            // horizontal drag carries the lens between icons.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _handleTapDown,
                onTapUp: _handleTapUp,
                onTapCancel: _handleTapCancel,
                onHorizontalDragStart: _handleDragStart,
                onHorizontalDragUpdate: _handleDragUpdate,
                onHorizontalDragEnd: (_) => _handleDragEnd(),
                onHorizontalDragCancel: _handleDragEnd,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRow({required Color color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _LensGeometry.padH),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _count; i++)
            Expanded(
              child: _NavItemVisual(
                destination: widget.destinations[i],
                selected: i == _visualIndex,
                pressed: i == _pressedIndex,
                color: color,
                labelSpace: _showLabels,
                showLabel:
                    widget.labelMode == NavLabelMode.always ||
                    (widget.labelMode == NavLabelMode.auto &&
                        i == _visualIndex),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTargets() {
    return Row(
      children: <Widget>[
        for (var i = 0; i < _count; i++)
          Expanded(
            child: Semantics(
              button: true,
              selected: i == widget.selectedIndex,
              label: widget.destinations[i].label,
              onTap: () => _select(i),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

/// One tab: a fixed 32dp icon band (matching the lens) plus a label.
class _NavItemVisual extends StatelessWidget {
  const _NavItemVisual({
    required this.destination,
    required this.selected,
    required this.pressed,
    required this.color,
    required this.labelSpace,
    required this.showLabel,
  });

  final LiquidNavDestination destination;
  final bool selected;
  final bool pressed;
  final Color color;

  /// Whether the bar reserves a label row (false = icon-only mode).
  final bool labelSpace;

  /// Whether the label is visible. In auto mode the space is still reserved
  /// for every item, so icons never jump when the selection moves.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final icon = AnimatedScale(
      scale: pressed ? 1.18 : (selected ? 1.06 : 1.0),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      child: Icon(
        selected ? destination.selectedIcon : destination.icon,
        size: 23,
        color: color,
      ),
    );

    if (!labelSpace) {
      return Center(child: icon);
    }

    return Column(
      children: <Widget>[
        const SizedBox(height: 9),
        SizedBox(height: 32, child: Center(child: icon)),
        const SizedBox(height: 1),
        AnimatedOpacity(
          opacity: showLabel ? 1 : 0,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 150),
          child: Text(
            destination.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.1,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.1,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared lens geometry so the painter, clippers and sheen never drift.
class _LensGeometry {
  const _LensGeometry._();

  static const double padH = 4;

  static double tabWidth(Size size, int count) =>
      (size.width - padH * 2) / count;

  static double centerX(Size size, double progress, int count) {
    final tab = tabWidth(size, count);
    final half = tab / 2;
    return (padH + (progress + 0.5) * tab)
        .clamp(padH + half, size.width - padH - half)
        .toDouble();
  }

  static RRect resolve(
    Size size, {
    required double progress,
    required double stretch,
    required double press,
    required int count,
  }) {
    final tab = tabWidth(size, count);
    // One size for both label modes: a near-circle that fills the bar's
    // height and wraps icon + label; hiding the labels must not shrink it.
    // Full tab width (Miuix's indicator width): at the first/last tab the
    // lens's 28-radius cap centre coincides with the bar's 32-radius cap
    // centre, so the bar reads as a constant 4dp stroke around the lens.
    final width = math.max(28.0, tab * (1 + stretch * 0.45 + press * 0.03));
    final height =
        (size.height - 8) * (1 - stretch.abs() * 0.08 + press * 0.03);
    final rect = Rect.fromCenter(
      center: Offset(centerX(size, progress, count), size.height / 2),
      width: width,
      height: height,
    );
    return RRect.fromRectAndRadius(rect, Radius.circular(height / 2));
  }

  /// The lens wraps the label too, so the accent band follows the lens
  /// width (plus a couple of pixels) rather than the whole item.
  static Rect band(Size size, double progress, int count) {
    final tab = tabWidth(size, count);
    final cx = centerX(size, progress, count);
    final width = tab;
    return Rect.fromLTRB(cx - width / 2, 0, cx + width / 2, size.height);
  }
}

class _LensClipper extends CustomClipper<Path> {
  const _LensClipper(this.rrect);

  final RRect rrect;

  @override
  Path getClip(Size size) => Path()..addRRect(rrect);

  @override
  bool shouldReclip(covariant _LensClipper oldClipper) =>
      oldClipper.rrect != rrect;
}

class _BandClipper extends CustomClipper<Path> {
  const _BandClipper(this.rect);

  final Rect rect;

  @override
  Path getClip(Size size) => Path()..addRect(rect);

  @override
  bool shouldReclip(covariant _BandClipper oldClipper) =>
      oldClipper.rect != rect;
}

/// Frosted capsule: blur + tint gradient + specular rim + soft shadow.
class _GlassSurface extends StatelessWidget {
  const _GlassSurface({
    required this.radius,
    required this.blurEnabled,
    required this.floating,
    required this.child,
  });

  final BorderRadius radius;
  final bool blurEnabled;
  final bool floating;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final top = cs.surfaceContainerLow.withValues(
      alpha: blurEnabled ? (isDark ? 0.50 : 0.46) : 1,
    );
    final bottom = cs.surfaceContainer.withValues(
      alpha: blurEnabled ? (isDark ? 0.40 : 0.36) : 1,
    );

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[top, bottom],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: isDark ? 0.04 : 0.09),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlassRimPainter(
                  radius: radius,
                  isDark: isDark,
                  floating: floating,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: floating
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.14),
                  blurRadius: 26,
                  spreadRadius: -4,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: blurEnabled
            ? BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: 18,
                  sigmaY: 18,
                  tileMode: TileMode.mirror,
                ),
                child: surface,
              )
            : surface,
      ),
    );
  }
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.radius,
    required this.isDark,
    required this.floating,
  });

  final BorderRadius radius;
  final bool isDark;
  final bool floating;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final outer = RRect.fromRectAndRadius(
      rect.deflate(0.6),
      Radius.circular(radius.topLeft.y),
    );
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.30 : 0.55),
            Colors.white.withValues(alpha: isDark ? 0.05 : 0.16),
            Colors.white.withValues(alpha: isDark ? 0.14 : 0.28),
          ],
        ).createShader(rect),
    );
    final inner = RRect.fromRectAndRadius(
      rect.deflate(1.6),
      Radius.circular(math.max(0, radius.topLeft.y - 1.6)),
    );
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.12 : 0.22),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    if (!floating) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, 0.8),
        Paint()
          ..color = isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GlassRimPainter old) =>
      old.isDark != isDark || old.radius != radius || old.floating != floating;
}

/// The compact glass thumb: M3-indicator-sized, tinted with
/// primaryContainer, with a small specular pool and a hairline rim.
class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required Listenable repaint,
    required this.progress,
    required this.stretch,
    required this.press,
    required this.count,

    required this.glass,
    required this.accent,
    required this.container,
    required this.isDark,
  }) : super(repaint: repaint);

  final Animation<double> progress;
  final ValueNotifier<double> stretch;
  final ValueNotifier<double> press;
  final int count;
  final bool glass;
  final Color accent;
  final Color container;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = _LensGeometry.resolve(
      size,
      progress: progress.value,
      stretch: stretch.value,
      press: press.value,
      count: count,
    );
    final rect = rrect.outerRect;

    if (!glass) {
      // Liquid glass off: a plain M3 indicator mask, no bloom, sheen or rim.
      canvas.drawRRect(
        rrect,
        Paint()..color = container.withValues(alpha: isDark ? 0.82 : 0.92),
      );
      return;
    }

    canvas.drawRRect(
      rrect.inflate(2),
      Paint()
        ..color = accent.withValues(alpha: isDark ? 0.14 : 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            container.withValues(alpha: isDark ? 0.52 : 0.60),
            accent.withValues(alpha: isDark ? 0.12 : 0.07),
          ],
        ).createShader(rect),
    );

    // A soft top sheen. Deliberately linear: the old radial gradient left a
    // visible little "dot" in the middle of the thumb.
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.06 : 0.11),
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
            Colors.white.withValues(alpha: isDark ? 0.24 : 0.52),
            Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter old) => false;

  @override
  bool shouldRebuildSemantics(covariant _SelectionPainter oldDelegate) => false;
}

/// A soft light band on the glass thumb.
class _SheenPainter extends CustomPainter {
  _SheenPainter({
    required Listenable repaint,
    required this.progress,
    required this.stretch,
    required this.press,
    required this.count,

    required this.isDark,
  }) : super(repaint: repaint);

  final Animation<double> progress;
  final ValueNotifier<double> stretch;
  final ValueNotifier<double> press;
  final int count;

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = _LensGeometry.resolve(
      size,
      progress: progress.value,
      stretch: stretch.value,
      press: press.value,
      count: count,
    );
    final rect = rrect.outerRect;
    final band = Rect.fromLTRB(
      rect.left + rect.width * 0.14,
      rect.top + 1.5,
      rect.right - rect.width * 0.14,
      rect.top + rect.height * 0.42,
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.05 : 0.11),
            Colors.transparent,
          ],
        ).createShader(band)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SheenPainter old) => false;
}

/// Optional refraction pass on the thumb: thick refracting rim, moving
/// caustic highlight and a faint chromatic fringe.
class _LensPainter extends CustomPainter {
  _LensPainter({
    required Listenable repaint,
    required this.progress,
    required this.stretch,
    required this.press,
    required this.count,

    required this.isDark,
  }) : super(repaint: repaint);

  final Animation<double> progress;
  final ValueNotifier<double> stretch;
  final ValueNotifier<double> press;
  final int count;

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = _LensGeometry.resolve(
      size,
      progress: progress.value,
      stretch: stretch.value,
      press: press.value,
      count: count,
    );
    final rect = rrect.outerRect;
    if (rect.width <= 2 || rect.height <= 2) return;

    canvas.save();
    canvas.clipRRect(rrect);

    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.05 : 0.09),
            Colors.transparent,
            Colors.white.withValues(alpha: 0.03),
          ],
        ).createShader(rect),
    );

    final caustic = Rect.fromLTRB(
      rect.left + 4,
      rect.top + 1.5,
      rect.right - 4,
      rect.top + rect.height * 0.42,
    );
    canvas.drawRect(
      caustic,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.12 : 0.20),
            Colors.transparent,
          ],
        ).createShader(caustic)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    canvas.drawRRect(
      rrect.deflate(1.4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            const Color(0xFFFF5C7A).withValues(alpha: isDark ? 0.14 : 0.10),
            Colors.transparent,
            const Color(0xFF5CD8FF).withValues(alpha: isDark ? 0.14 : 0.10),
          ],
        ).createShader(rect),
    );

    canvas.drawRRect(
      rrect.deflate(0.9),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: isDark ? 0.34 : 0.56),
            Colors.white.withValues(alpha: isDark ? 0.05 : 0.12),
            Colors.white.withValues(alpha: isDark ? 0.14 : 0.22),
            Colors.white.withValues(alpha: 0.04),
          ],
          stops: const <double>[0, 0.35, 0.7, 1],
        ).createShader(rect),
    );

    canvas.drawRRect(
      rrect.deflate(2.0),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.transparent,
            Colors.black.withValues(alpha: isDark ? 0.14 : 0.07),
          ],
        ).createShader(rect),
    );

    canvas.restore();

    canvas.drawRRect(
      rrect.deflate(0.3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: isDark ? 0.10 : 0.16),
    );
  }

  @override
  bool shouldRepaint(covariant _LensPainter oldDelegate) => false;
}
