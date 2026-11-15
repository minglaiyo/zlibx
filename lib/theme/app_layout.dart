import '../models/grid_columns_mode.dart';

/// Material 3 的窗口尺寸分档（逻辑像素）。
///
/// 只留应用真正会反应的边界：[medium] 是手机结束、平板开始的地方，
/// [expanded] 是平板宽到可以给页面更宽的左右留白。
abstract final class AppBreakpoints {
  /// 窄于这个宽度算手机；平板栅格从这里开始。
  static const double medium = 600;

  /// 大屏平板 / 桌面窗口：更宽的页面左右留白。
  static const double expanded = 1240;
}

/// 网格布局共用的响应式规则。
///
/// 一切都从当前宽度算（[LayoutBuilder] 的 constraints 或 MediaQuery），
/// 所以 7 寸竖屏平板、平板横屏、折叠屏半开、桌面自由窗口都能得到合理
/// 的列数，不需要额外配置。
abstract final class AppLayout {
  /// 格与格之间的水平间距。
  static const double gridSpacing = 16;

  /// 卡片最窄能到多少，再窄就减一列。手机保持设计上的 3 列密度
  /// （411dp 宽的屏 ≈ 113dp 一张卡）。
  static const double minCardWidth = 112;

  /// 上限：窗口再宽也不让封面缩成邮票。
  static const int maxGridColumns = 8;

  /// 首页网格（及其悬浮头部）的左右留白。
  static double pageGutter(double width) {
    if (width >= AppBreakpoints.expanded) return 48;
    if (width >= AppBreakpoints.medium) return 32;
    return 20;
  }

  /// [availableWidth] 这一档模式该用几列。传网格盒子自身的宽度（窗口
  /// 宽，页面留白在这里头扣）。
  ///
  /// 手动档直接给列数。[GridColumnsMode.auto] 下手机在任何宽度都是 3
  /// 列：360dp 的机器不能因为算术上只塞得下 2 张 112dp 的卡就自己掉到
  /// 2 列——设计从头到尾就是 3 列。真正需要自适应的是平板断点往上，
  /// 那里多出来的宽度确实装得下更多列。
  static int gridColumns(GridColumnsMode mode, double availableWidth) {
    final fixed = mode.fixedColumns;
    if (fixed != null) return fixed;
    if (availableWidth < AppBreakpoints.medium) return 3;
    final contentWidth = availableWidth - 2 * pageGutter(availableWidth);
    final fitting =
        ((contentWidth + gridSpacing) / (minCardWidth + gridSpacing)).floor();
    return fitting.clamp(3, maxGridColumns).toInt();
  }
}
