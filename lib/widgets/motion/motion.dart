library;

/// 动效组件族（v2 统一入口）：
/// - [MotionEntrance] 列表/网格条目错峰入场
/// - [MotionSwitch]   状态切换过渡（fade/scale/slide/size）
/// - [MotionShimmer]  共享控制器的骨架屏扫光 + SkeletonBox/SkeletonCircle
/// token 在 `theme/motion.dart`（MotionCurves/MotionPress/Motion + 扩展）。
export 'entrance.dart';
export 'skeleton.dart';
export 'switch.dart';
