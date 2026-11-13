import 'package:flutter/material.dart';

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
/// 宽度钳在 100~800（800 是实测过的最大值）。
String coverUrlAtWidth(String url, int width) {
  final w = width.clamp(100, 800);
  return url.replaceFirstMapped(
    RegExp(r'/covers\d+/'),
    (m) => '/covers$w/',
  );
}
