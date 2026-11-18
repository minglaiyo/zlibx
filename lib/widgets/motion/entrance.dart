import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/motion.dart';


/// 列表/网格条目的一次性错峰入场（淡入 + 轻微上滑）。
///
/// [TweenAnimationBuilder] 在条目首次构建时自播一次。[index] 越大
/// 起始越晚（每档 [staggerMs] 毫秒，最多 [maxIndex] 档）形成瀑布感；
/// 超过 [maxIndex]（视口外懒加载的新项）直接返回 child，避免滚动过
/// 程中反复触发。系统关闭动画时同样跳过。
///
/// 网格按行错峰的场合，调用方传 `index ~/ columns` 当档位即可，
/// 不需要专门的网格变体。
class MotionEntrance extends StatelessWidget {
  const MotionEntrance({
    super.key,
    required this.index,
    required this.child,
    this.maxIndex = 8,
    this.staggerMs = 30,
    this.duration = AppMotion.medium,
    this.offsetY = 10.0,
  });

  /// 条目在列表里的序号；也接受自定义档位（网格按行错峰时传行号）。
  final int index;

  final Widget child;

  /// 参与进场动画的最大档位。
  final int maxIndex;

  /// 每档之间的延迟（毫秒）。
  final int staggerMs;

  final Duration duration;

  /// 初始垂直偏移量（像素），正值从下方进入。
  final double offsetY;

  @override
  Widget build(BuildContext context) {
    if (index >= maxIndex || context.disableAnimations) {
      return child;
    }

    // 错峰用 Interval 实现（延迟档位压缩动画窗口），不是延迟启动：
    // 这样每条的 TweenAnimationBuilder 时长一致，瀑布只差相位。
    final delayFactor =
        (index * staggerMs) / duration.inMilliseconds;
    final clamped = delayFactor.clamp(0.0, 2.0);
    final timing = Duration(
      milliseconds: (duration.inMilliseconds * (1 + clamped)).round(),
    );
    final curve = Interval(
      clamped / (1 + clamped),
      1.0,
      curve: MotionCurves.enter,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: timing,
      curve: curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * offsetY),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
