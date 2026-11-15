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

/// 书籍网格共用的响应式规则，外观设置里"自适应列数"那个开关打开时
/// 全站走这里，关掉时各页面维持各自的固定/按最大宽度估列数的老委托
/// （见 [legacyGridColumns]）。
///
/// 一切都从当前宽度算（[LayoutBuilder] 的 constraints），所以 7 寸竖屏
/// 平板、平板横屏、折叠屏半开、桌面自由窗口都能得到合理的列数。首页、
/// 最新上架、热门、同类、搜索结果共用同一套列数与间距；卡片种类的不同
/// （纯封面 vs 带书名信息）只体现在一格多高上，见 `BookCard.gridHeightFor`。
abstract final class AppLayout {
  /// 自适应档：格与格之间的水平间距。
  static const double gridSpacing = 16;

  /// 自适应档：卡片最窄能到多少，再窄就减一列。手机保持设计上的 3 列
  /// 密度（411dp 宽的屏 ≈ 113dp 一张卡）。
  static const double minCardWidth = 112;

  /// 自适应档：列数上限，窗口再宽也不让封面缩成邮票。
  static const int maxGridColumns = 8;

  /// 老规则（开关关掉时）：卡片最大宽度。
  static const double legacyMaxCardWidth = 220;

  /// 老规则：首页左右留白固定 20，不分档。
  static const double legacyGutter = 20;

  /// 自适应档下网格（及首页悬浮头部）的左右留白。
  static double pageGutter(double width) {
    if (width >= AppBreakpoints.expanded) return 48;
    if (width >= AppBreakpoints.medium) return 32;
    return 20;
  }

  /// 自适应档：该排几列。全站书籍网格共用这一个规则——首页的纯封面卡和
  /// 最新上架 / 热门 / 同类 / 搜索结果的带信息卡都是同样的列数与同样的
  /// 16dp 间距，差别只在格子多高：前者按封面比例，后者用
  /// `BookCard.gridHeightFor` 把信息区算进去，所以窄格不会把封面裁成
  /// 一条横带。
  ///
  /// 下限 3 列：360dp 的机器算术上只塞得下 2 张 112dp 的卡，但设计从头
  /// 到尾就是 3 列，不能因为屏幕略窄就自己掉到 2 列。真正需要自适应的是
  /// 宽度富余之后——那里多出来的宽度确实装得下更多列。
  static int gridColumns(double availableWidth) {
    final contentWidth = availableWidth - 2 * pageGutter(availableWidth);
    final fitting =
        ((contentWidth + gridSpacing) / (minCardWidth + gridSpacing)).floor();
    return fitting.clamp(3, maxGridColumns).toInt();
  }

  /// 老规则：按 [contentWidth]（已扣掉左右留白的网格宽度）估列数——
  /// 卡片不超过 [legacyMaxCardWidth] 为准，所以 360/411dp 的手机上实际
  /// 只有 2 列。原样保留给"自适应列数"关掉那一档用：这就是
  /// `SliverGridDelegateWithMaxCrossAxisExtent` 内部的公式（
  /// `(宽度 / (最大卡宽 + 间距)).ceil()`，最少 1 列，见 rendering/
  /// sliver_grid.dart 的 getLayout），1.6.0 之前首页用的就是那个委托，
  /// 所以开关关掉时的排布和旧版逐像素一致。
  static int legacyGridColumns(double contentWidth) {
    final columns =
        (contentWidth / (legacyMaxCardWidth + gridSpacing)).ceil();
    return columns < 1 ? 1 : columns;
  }
}
