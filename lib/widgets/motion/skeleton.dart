import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';
import '../../theme/motion.dart';

/// 骨架屏 shimmer：全 app 共享一个控制器，所有可见的 shimmer 同相位。
///
/// 一屏 50 张加载封面曾经 = 50 个 AnimationController（50 个 ticker）；
/// 这里由当前允许动画的消费者（系统动画开 + TickerMode 开）引用计数，
/// 第一个消费者启动 repeat，最后一个停止——后台路由不拖 ticker。
///
/// [builder] 拿到共享动画（-1 → 2 的 double），自己画扫过效果；
/// 常用形状直接用 [SkeletonBox] / [SkeletonCircle] 叠在 shimmer 里。
class MotionShimmer extends StatefulWidget {
  const MotionShimmer({super.key, required this.builder});

  /// 每帧重建的扫过效果。animation.value 走 -1 → 2，方便把高光带
  /// 从左上扫到右下（stops 通常取 value±0.3 再 clamp）。
  final Widget Function(BuildContext context, Animation<double> animation)
  builder;

  @override
  State<MotionShimmer> createState() => _MotionShimmerState();
}

/// 一个控制器服务所有 shimmer。裸 [Ticker]：TickerMode 静音由引用
/// 计数处理，不依赖单个 widget 的 mixin。
class _SharedShimmer {
  _SharedShimmer._();

  static final _SharedShimmer instance = _SharedShimmer._();

  final TickerProvider _vsync = _BareTickerProvider();

  late final AnimationController _controller = AnimationController(
    vsync: _vsync,
    duration: AppMotion.shimmer,
  );

  late final Animation<double> animation = _controller.withCurve(
    Tween<double>(begin: -1.0, end: 2.0),
    curve: MotionCurves.shimmer,
  );

  int _consumers = 0;

  void attach() {
    _consumers++;
    if (!_controller.isAnimating) _controller.repeat();
  }

  void detach() {
    if (_consumers > 0) _consumers--;
    if (_consumers == 0) _controller.stop();
  }
}

class _BareTickerProvider implements TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

class _MotionShimmerState extends State<MotionShimmer> {
  bool _attached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldAnimate =
        !context.disableAnimations && TickerMode.valuesOf(context).enabled;
    if (shouldAnimate == _attached) return;
    _attached = shouldAnimate;
    if (shouldAnimate) {
      _SharedShimmer.instance.attach();
    } else {
      _SharedShimmer.instance.detach();
    }
  }

  @override
  void dispose() {
    if (_attached) {
      _attached = false;
      _SharedShimmer.instance.detach();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = _SharedShimmer.instance.animation;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => widget.builder(context, animation),
    );
  }
}

/// 骨架形状：静态占位盒子（不带 shimmer——呼吸式骨架列表直接叠它，
/// 扫光式把 [MotionShimmer] 套在外面）。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 8,
    this.color,
  });

  final double? width;
  final double? height;
  final double radius;

  /// 缺省取当前主题的 surfaceContainerHighest（深浅色自动适配）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 圆形骨架占位（头像等）。
class SkeletonCircle extends StatelessWidget {
  const SkeletonCircle({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}
