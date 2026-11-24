// URL 掩码（2026-11-24）：下载失败那句要说出**卡在哪一跳**，但绝不能把
// token、会话或书名原样打在屏上——这几行文案会被截图发出来。所以规则很
// 明确：主机和路径结构留着（判断依据），token 和长 slug 折成"头 4 位…
// 尾 2 位"，带点的段按文件名只截长度（扩展名是证据，不是隐私）。
//
// 这套掩码是**承重**的，不是探针的一部分：任何往用户可见文本里写 URL 的
// 地方都得先过它。
part of 'zlibrary_api.dart';

String _maskUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final segs = uri.pathSegments.map(_maskUrlToken).toList();
  final query = uri.queryParameters.isEmpty
      ? ''
      : '?${uri.queryParameters.keys.join(",")}';
  return '${uri.host}/${segs.join("/")}$query';
}

String _maskUrlToken(String value) {
  // 带点的段是文件名——扩展名（epub / pdf / zip）正是"这一跳到底给了
  // 什么"的证据，掩掉就没有意义，所以只截长度。
  if (value.contains('.')) return _clipLabel(value);
  if (value.length <= 8) return value;
  return '${value.substring(0, 4)}…${value.substring(value.length - 2)}';
}

String _clipLabel(String value) =>
    value.length <= 28 ? value : '${value.substring(0, 28)}…';
