import 'package:flutter/material.dart';
import 'app_metrics.dart';

/// 全 app 动效系统（v2，整体重写版）的唯一 token 入口。
///
/// 时长在 [AppMotion]（app_metrics.dart），曲线/按压/无障碍在这里。
/// 组件族在 `widgets/motion/`（MotionEntrance / MotionSwitch /
/// MotionShimmer）——调用方只 import 这两个文件，不手写
/// AnimationController / TweenAnimationBuilder / 裸 Curves。
abstract final class Motion {
  /// 系统是否要求关闭动画（无障碍设置）。context 可空：拿不到
  /// context 时回退全局平台设置。
  static bool disabled(BuildContext? context) {
    if (context != null) {
      return MediaQuery.disableAnimationsOf(context);
    }
    return WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
  }

  /// 尊重无障碍设置的时长：禁用动画时返回 [Duration.zero]。
  static Duration durationOf(Duration duration, {BuildContext? context}) =>
      disabled(context) ? Duration.zero : duration;
}

/// 缓动曲线 token。命名按用途，不按视觉（"standard" 这种名字三周后
/// 谁也想不起来它是什么曲线）。
abstract final class MotionCurves {
  /// 入场/展开：减速曲线，绝大多数进场场景。
  static const Curve enter = Curves.easeOutCubic;

  /// 退出/隐藏：加速曲线，与 enter 成对。
  static const Curve exit = Curves.easeIn;

  /// 强调：比 enter 更快的减速，按压、重要状态变化。
  static const Curve emphasized = Curves.easeOutQuart;

  /// 弹性：logo 入场等活泼场景。
  static const Curve elastic = Curves.elasticOut;

  /// 匀速：旋转等持续动画。
  static const Curve linear = Curves.linear;

  /// 往复：呼吸/脉冲等 ease-in-out 循环。
  static const Curve loop = Curves.easeInOut;

  /// 骨架屏扫过。
  static const Curve shimmer = Curves.easeInOutSine;
}

/// 按压反馈 token（书卡等自带手势的组件直接用这三个常量配
/// AnimatedScale，不需要额外包装组件）。
abstract final class MotionPress {
  static const double scale = 0.96;
  static const Duration duration = AppMotion.fast;
  static const Curve curve = MotionCurves.enter;
}

/// BuildContext 侧的无障碍感知工具。
extension MotionContextX on BuildContext {
  /// 系统关闭动画时为 true——自定义动画的组件必须检查它。
  bool get disableAnimations => Motion.disabled(this);

  /// 根据无障碍设置调整时长（禁用时 Duration.zero）。
  Duration motionDuration(Duration duration) =>
      Motion.durationOf(duration, context: this);
}

/// AnimationController 的常用装配：配曲线、配分段 Interval。
/// splash 等多控制器场景用它们代替手写 CurvedAnimation。
extension MotionControllerX on AnimationController {
  Animation<T> withCurve<T>(Tween<T> tween, {Curve curve = MotionCurves.enter}) {
    return tween.animate(CurvedAnimation(parent: this, curve: curve));
  }

  Animation<T> withInterval<T>(
    Tween<T> tween, {
    required double begin,
    required double end,
    Curve curve = MotionCurves.enter,
  }) {
    return tween.animate(
      CurvedAnimation(parent: this, curve: Interval(begin, end, curve: curve)),
    );
  }
}
