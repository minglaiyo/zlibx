import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models/display_book.dart';
import 'diagnostics.dart';

/// 封面图的内存解码尺寸：按显示逻辑尺寸 × 设备像素比取整。
///
/// Z-Library 封面原图普遍 500 KB ~ 1.5 MB，不设上限时解码后位图
/// 可达数 MB——长列表快速滑动时 GC 压力直接变成掉帧。此前 8 处
/// 调用点各自手写这个换算，统一到这里（见各调用点 `memCacheWidth`
/// / `memCacheHeight`）。
int coverCacheWidth(double logicalWidth, BuildContext context) =>
    (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil();

/// 与 [coverCacheWidth] 同规则的高度版：只在渲染高宽比已知时用
/// （固定尺寸缩略图、按宽高比算高的封面卡片）。
int coverCacheHeight(double logicalHeight, BuildContext context) =>
    (logicalHeight * MediaQuery.devicePixelRatioOf(context)).ceil();

/// 封面专用磁盘缓存。默认 flutter_cache_manager 实例是 200 个对象 /
/// 30 天：300 档封面单张几十 KB，翻几屏就把早先的封面挤出去，回滚
/// 列表、回首页时会反复重新下载。封面是小文件，放宽到 1500 张 /
/// 60 天（约 45 MB 量级）；设置页暂无清缓存入口，容量按保守值取。
/// 所有封面 [CachedNetworkImage] 都传 `cacheManager: coverCacheManager`。
final CacheManager coverCacheManager = CacheManager(
  Config(
    'zlibx_covers',
    stalePeriod: const Duration(days: 60),
    maxNrOfCacheObjects: 1500,
  ),
);

/// I6: 数据到达后立刻预热前 [count] 张封面的磁盘缓存。`downloadFile`
/// 只下载不解码（不占内存图像缓存），卡片进入视口前图已在盘上。
/// 预热走 400 档——常见 DPR（2.75/3.0）的网格档位；低 DPR 设备的
/// 网格用 300 档时会再补一次小下载。
Future<void> _warmCover(CacheManager manager, String url) async {
  try {
    await manager.downloadFile(url);
  } on Object catch (e) {
    // 失败只放弃预热：预取是纯优化，不能变成首屏报错源。
    logIgnored('cover_warm', e);
  }
}

void warmCoverDiskCache(Iterable<DisplayBook> books, {int count = 9}) {
  for (final b in books.take(count)) {
    final c = b.cover;
    if (c == null || c.isEmpty) continue;
    unawaited(_warmCover(coverCacheManager, coverUrlAtWidth(c, 400)));
  }
}

/// 实测过的 CDN 档位（见 [coverUrlAtWidth] 的注释）。
const List<int> _kCoverBuckets = [100, 200, 300, 400, 500, 600, 800];

final RegExp _kCoversRe = RegExp(r'/covers\d+/');

/// 把显示像素宽度向上对齐到最近的不小于它的档位。
///
/// 逻辑宽度 × DPR 常算出 325、480 这类非档位值：非标准档位在 CDN
/// 上命中率低（要走动态缩放或回源），而且不同机型、不同页面算出
/// 的宽度不同，同一本书的 URL 互不相同，磁盘缓存互相不命中。URL
/// 统一向上取整到档位；解码尺寸仍由 [coverCacheWidth] 给出，两者
/// 各管各的。
int coverBucket(int px) {
  for (final b in _kCoverBuckets) {
    if (b >= px) return b;
  }
  return _kCoverBuckets.last;
}

/// 把 Z-Library 封面 URL 换成指定宽度的版本。
///
/// 封面 CDN（s3proxy-*-covers.cdn-zlib.sk）按路径里的宽度分桶动态
/// 出图：列表页给的是 `/covers100/...`（100px 宽的缩略图），
/// `/covers200/`、`/covers300/`、`/covers800/` 依此类推——2026-11-13
/// 实测 covers100/200/300/400/500/600/800 均返回对应宽度的真图
/// （100x150、200x300、300x450、400x600、500x750、600x900、
/// 800x1200）。直接按格宽解码 covers100 会糊；按展示宽度要图：
/// 列表/网格 300、详情大图 800。
/// 不是 covers 链接（Anna/LibGen 封面、本地路径、空串）原样返回。
/// 宽度钳在 100~800（800 是实测过的最大值），再向上对齐到档位。
String coverUrlAtWidth(String url, int width) {
  final w = coverBucket(width.clamp(100, 800));
  return url.replaceFirst(_kCoversRe, '/covers$w/');
}
