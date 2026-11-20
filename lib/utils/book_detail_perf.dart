// 详情页加载计时（诊断构建专用，2026-11-21，定位完撤）。
//
// 详情页"完全加载"唯一等网络的活是 getBookInfo 的 eapi 请求（1~3
// 连发：短 hash 的书要先按标题解析再取）。计时直接在详情页屏上一行
// 小字显示——Diagnostics 轨迹全库没有查看出口、AppLog debug 级
// release 不打，都到不了看包人的眼睛里。内容只有毫秒数与静态词
// （ok/fail/hit/miss），无书名无 URL，符合日志隐私约定。
import 'package:flutter/foundation.dart';

/// 屏上显示的最后一行计时。
final ValueNotifier<String> bookDetailPerf = ValueNotifier<String>('');

final List<String> _stages = <String>[];

/// vendor [ZLibraryApiBase.perfHook] 的落点：汇分段行。新一次调用以
/// fetch1= 开头，见到即重置缓冲（一次 getBookInfo 的分段归一组）。
void bookDetailPerfStage(String line) {
  if (line.startsWith('fetch1=')) _stages.clear();
  _stages.add(line);
}

/// 一次 getBookInfo 结束：总耗时 + 分段一起上屏。
void bookDetailPerfFinish(int totalMs, bool ok) {
  final stages = _stages.isEmpty ? '' : ' | ${_stages.join(' · ')}';
  bookDetailPerf.value = 'eapi ${totalMs}ms ${ok ? 'ok' : 'fail'}$stages';
}

/// 详情磁盘缓存命中：0 请求直接渲染。
void bookDetailPerfCacheHit() {
  _stages.clear();
  bookDetailPerf.value = 'eapi cache 0 请求';
}
