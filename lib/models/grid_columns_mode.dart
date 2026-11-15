/// 推荐页网格的列数来源（设置 → 外观 → 推荐页列数）。
///
/// [auto] 是默认：列数跟着窗口宽度走（手机 3 列，平板 4–8 列，见
/// `AppLayout.gridColumns`），这样 7 寸竖屏、平板横屏、折叠屏半开和
/// 桌面自由窗口都能拿到合理的密度，不需要用户再挑一次。[two] /
/// [three] 留给就是要固定密度的用户。[four] 不只是列数——它换的是渲染
/// 方式（官方 App 那种纯封面密排格，无边框卡片、无徽标）。
enum GridColumnsMode {
  auto,
  two,
  three,
  four;

  /// 手动档的列数；[auto] 返回 null，表示由宽度决定。
  int? get fixedColumns => switch (this) {
    GridColumnsMode.auto => null,
    GridColumnsMode.two => 2,
    GridColumnsMode.three => 3,
    GridColumnsMode.four => 4,
  };

  /// 这一档要不要用纯封面格而不是带信息区的卡片。判断只写在这里，
  /// 网格和设置页共用，免得两边各比一次 `== four`。
  bool get coverTiles => this == GridColumnsMode.four;
}
