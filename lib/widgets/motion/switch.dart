import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/motion.dart';


/// 切换过渡的形态。
enum MotionSwitchStyle {
  /// 纯淡入淡出：三态容器（loading/empty/error/content）的默认。
  fade,

  /// 淡入 + 缩放：图标、小型状态切换（收藏心形、下载状态）。
  scale,

  /// 淡入 + 上滑：文本/卡片内容切换。
  slide,

  /// 淡入 + 高度展开：条目的出现/消失（筛选行、折叠区）。
  /// 高度动画是 top-anchored 的（axisAlignment -1）。
  size,
}

/// 状态切换的统一过渡容器：包一层 [AnimatedSwitcher]。
///
/// **子 widget 必须带稳定且互不相同的 Key**——AnimatedSwitcher 靠
/// key 判断是否需要过渡（调用方用 `ValueKey('loading')` /
/// `ValueKey('content')` 之类）。
class MotionSwitch extends StatelessWidget {
  const MotionSwitch({
    super.key,
    required this.child,
    this.style = MotionSwitchStyle.fade,
    this.duration = AppMotion.medium,
    this.curve = MotionCurves.enter,
    this.exitCurve = MotionCurves.exit,
  });

  final Widget child;
  final MotionSwitchStyle style;
  final Duration duration;

  /// 入场曲线；小型状态切换（图标等）常用 emphasized。
  final Curve curve;

  /// 退出曲线，与 [curve] 成对（退比进快）。
  final Curve exitCurve;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: context.motionDuration(duration),
      switchInCurve: curve,
      switchOutCurve: exitCurve,
      transitionBuilder: (child, animation) =>
          _transition(style, child, animation),
      child: child,
    );
  }
}

Widget _transition(
  MotionSwitchStyle style,
  Widget child,
  Animation<double> animation,
) {
  switch (style) {
    case MotionSwitchStyle.fade:
      return FadeTransition(opacity: animation, child: child);
    case MotionSwitchStyle.scale:
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      );
    case MotionSwitchStyle.slide:
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.15),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      );
    case MotionSwitchStyle.size:
      return FadeTransition(
        opacity: animation,
        // "Top-anchored" 用 axis + axisAlignment（-1 = 顶对齐）表达。
        // 本地 3.41.x 工具链没有 SizeTransition.alignment（那是当初
        // 的报错来源），3.44 又把 axisAlignment 标记废弃——保留
        // 3.41 兼容写法并压掉新工具链的废弃提示。
        child: SizeTransition(
          sizeFactor: animation,
          axis: Axis.vertical,
          // ignore: deprecated_member_use
          axisAlignment: -1,
          child: child,
        ),
      );
  }
}
