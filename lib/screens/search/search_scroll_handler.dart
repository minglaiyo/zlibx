/// Scroll-driven header fold + load-more trigger for the search
/// screen (P1-4 split of search_screen.dart).
library;

import 'package:flutter/material.dart';

class SearchScrollHandler {
  SearchScrollHandler({required this.onLoadMore});

  /// Called when the results list scrolls to within 200px of the
  /// bottom; the screen dispatches to the current source/mode's
  /// provider.
  final VoidCallback onLoadMore;

  /// Whether the source / mode / filter-chip header is shown. It
  /// folds away (animated) while the user scrolls down through the
  /// results and folds back in when scrolling back up; a fresh
  /// search always brings it back (see [reset]). ValueNotifier:
  /// folding/unfolding only rebuilds the header chips column
  /// (review B2).
  final ValueNotifier<bool> headerVisible = ValueNotifier(true);

  /// Pixels of accumulated scroll in one direction before the
  /// header folds away (down) or back in (up).
  static const double _scrollHideThreshold = 12;

  /// Accumulated scroll delta in the current direction, for the
  /// fold threshold above. A single pixel's delta is noise
  /// (overscroll, fling settle), so the direction must persist —
  /// a slow drag still folds the header once it has moved this far.
  double _scrollAccum = 0;

  /// A fresh search reloads the results from the top, so a
  /// scroll-folded header comes back with them (and the accumulated
  /// scroll direction starts over). ValueNotifier 写入即可——值相同不
  /// 通知，头部自己收。
  void reset() {
    _scrollAccum = 0;
    headerVisible.value = true;
  }

  /// 滚动加载走气泡通知（结果区在 `SearchBodyView` 里由结果分支包
  /// NotificationListener）：不再需要 ScrollController，网格↔列表
  /// 切换的 AnimatedSwitcher 过渡期间新旧两个列表才能同时在树上。
  /// 阈值与原 controller 监听一致；重复触发由各 provider 的
  /// isLoadingMore / totalPages 守卫兜底。
  ///
  /// 同时管搜索栏下方那组标题（来源 / 模式 / 筛选 chips）的收起：
  /// 往下翻结果时收起来、往回翻时展开、回到顶部时一定展开。
  /// 只认 ScrollUpdateNotification 的 delta（正 = 往下翻 = 收起，
  /// 负 = 往回翻 = 展开），按方向累计到阈值才动，避免抖动。折叠/
  /// 展开走 [headerVisible] ValueNotifier——只在头部 chips 列上
  /// 重建，整屏不跟（审查 B2 前的实际行为是每个折叠帧整屏 setState）。
  bool onScrollNotification(ScrollNotification n) {
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
      onLoadMore();
    }
    if (n.metrics.pixels <= 0) {
      // Back at the top: the header always comes back.
      _scrollAccum = 0;
      headerVisible.value = true;
      return false;
    }
    final delta = n is ScrollUpdateNotification ? n.scrollDelta : null;
    if (delta != null && delta != 0) {
      if (_scrollAccum == 0 || delta.sign == _scrollAccum.sign) {
        _scrollAccum += delta;
      } else {
        _scrollAccum = delta;
      }
      if (_scrollAccum > _scrollHideThreshold && headerVisible.value) {
        _scrollAccum = 0;
        headerVisible.value = false;
      } else if (_scrollAccum < -_scrollHideThreshold &&
          !headerVisible.value) {
        _scrollAccum = 0;
        headerVisible.value = true;
      }
    }
    return false;
  }

  void dispose() => headerVisible.dispose();
}
