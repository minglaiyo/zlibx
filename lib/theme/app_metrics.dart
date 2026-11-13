import 'package:flutter/material.dart';

/// 全 app 圆角基线。此前 93 处 `BorderRadius.circular` 散落 14 种
/// 取值（8/12/30/16 占 58 处）；新代码必须用这里，触碰到的旧代码
/// 顺手替换——不做一次性全库替换，控制 diff 噪音。
abstract final class AppRadius {
  /// 卡片/大容器（12）。
  static const BorderRadius card = BorderRadius.all(Radius.circular(12));

  /// 小缩略图/内嵌元素（8）。
  static const BorderRadius thumb = BorderRadius.all(Radius.circular(8));

  /// 大横幅/弹窗（16）。
  static const BorderRadius sheet = BorderRadius.all(Radius.circular(16));

  static BorderRadius circular(double value) => BorderRadius.circular(value);
}

/// 全 app 间距基线。此前 100+ 处 `SizedBox(height/width:)` 散落
/// 8 种取值；收敛策略同 [AppRadius]。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 全 app 动效时长基线。此前动画时长散落 30+ 处（150/180/200/250/
/// 300/400/900/1500ms 等）；收敛策略同 [AppRadius] / [AppSpacing]：
/// 新代码必须用这里，触碰到的旧代码顺手替换，不做一次性全库替换。
///
/// 这里只收动画时长：网络超时、防抖 Timer、`Future.delayed` 等非动画
/// 用途的 Duration 保持原样。
abstract final class AppMotion {
  /// 微反馈：按下/松开、淡入淡出（150）。
  static const Duration fast = Duration(milliseconds: 150);

  /// 小部件展开/收起、着色过渡（180）。
  static const Duration quick = Duration(milliseconds: 180);

  /// 选中态、轻量切换（200）。
  static const Duration standard = Duration(milliseconds: 200);

  /// 导航栏、中等距离位移（250）。
  static const Duration medium = Duration(milliseconds: 250);

  /// 页面转场、明显位移（300）。
  static const Duration slow = Duration(milliseconds: 300);

  /// 大段滚动、进场动画（400）。
  static const Duration slower = Duration(milliseconds: 400);

  /// 骨架 shimmer 的循环周期（1500）。
  static const Duration shimmer = Duration(milliseconds: 1500);

  /// 启动页内容错峰入场（800）。
  static const Duration verySlow = Duration(milliseconds: 800);

  /// 最长过渡：启动页 logo 入场、书单骨架呼吸（900）。
  static const Duration slowest = Duration(milliseconds: 900);

  /// 启动页 logo 呼吸脉冲的完整周期（2000，reverse 往复）。
  static const Duration pulse = Duration(milliseconds: 2000);

  /// 3D 封面静置漂移的慢速循环（9s）——远超普通过渡的持续氛围动画。
  static const Duration idleDrift = Duration(seconds: 9);
}

/// 全 app 悬浮阴影基线。同一颗胶囊的阴影此前明暗模式各自为政：
/// favorites/booklists 是 dark ? 0.2 : 0.06，home_tab/similar 固定
/// 0.06 —— 深色模式下同一个组件一个有浮起感一个没有。新代码从这
/// 取，触碰到的旧代码顺手替换，不做一次性全库替换。
abstract final class AppShadows {
  /// 悬浮胶囊 / 圆形快捷按钮（搜索入口、头部分类/最新按钮）：
  /// 深色模式加深，否则黑影在深色底上几乎不可见。
  static List<BoxShadow> elevated(Brightness brightness) => [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: brightness == Brightness.dark ? 0.2 : 0.06,
          ),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];
}
