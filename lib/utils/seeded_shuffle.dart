import 'dart:math';

/// 确定性（伪随机）洗牌，用于首页推荐排序。
///
/// "伪随机"的含义：同一种子永远得到同一顺序。首页推荐用当天日期做
/// 种子（[daySeed]），于是推荐顺序与站点的固定榜单不同、每天换一副
/// "牌"，但同一天内重进、滚动、重排都不会中途重洗——不会出现列表
/// 闪动，翻页加载也接得上。
///
/// 只用于展示层排序，不涉及任何安全场景，用 [Random] 的普通伪随机
/// 流即可（非加密安全）。
List<T> seededShuffle<T>(List<T> items, int seed) {
  final list = List<T>.of(items);
  final rng = Random(seed);
  for (var i = list.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = list[i];
    list[i] = list[j];
    list[j] = tmp;
  }
  return list;
}

/// 推荐洗牌的日种子：纯数值日期分量拼合，不含 [String.hashCode] ——
/// 它的算法随 Dart 版本可能变化，会让历史顺序悄悄漂移。
int daySeed(DateTime now) =>
    now.year * 10000 + now.month * 100 + now.day;
