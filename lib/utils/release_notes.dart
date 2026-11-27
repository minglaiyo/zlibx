/// GitHub Release 正文清洗（计划一第 16 项）：更新弹窗里只显示干净的
/// 更新内容，不显示 APK 文件名。
///
/// - 截掉正文里 `## 下载` 及之后的内容（APK 文件名在那一段）；
/// - 去掉首行标题（`#...`）；
/// - Markdown 转纯文本：链接变文字、去加粗/代码标记、标题变小节、
/// 列表符号变 ·。
///
/// 输入是 [UpdateManifest] 去掉清单块后的 notes；输出可直接放进
/// Text 里展示。纯函数，可单元测试。
String sanitizeReleaseNotes(String body) {
  final lines = body.split('\n');

  // 1. 截掉 `## 下载` 及之后：APK 文件名、下载链接都在那一段。
  var end = lines.length;
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^##\s*下载').hasMatch(lines[i].trim())) {
      end = i;
      break;
    }
  }
  final kept = lines.sublist(0, end);

  // 2. 去掉首行标题：第一个非空行是 `#...` 时删掉。
  var start = 0;
  while (start < kept.length && kept[start].trim().isEmpty) {
    start++;
  }
  if (start < kept.length &&
      RegExp(r'^#\s+').hasMatch(kept[start].trim())) {
    start++;
  }

  // 3. 逐行转纯文本。
  final out = <String>[];
  var blankRun = 0;
  for (var i = start; i < kept.length; i++) {
    final line = _plainLine(kept[i]);
    if (line.isEmpty) {
      // 多个连续空行压成一个。
      blankRun++;
      if (blankRun == 1 && out.isNotEmpty) out.add('');
      continue;
    }
    blankRun = 0;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// 一行 Markdown 转纯文本。
String _plainLine(String raw) {
  var line = raw.trim();
  // 分隔线（--- / ***）不显示。
  if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(line)) return '';
  // 引用去掉 `>` 前缀。
  if (line.startsWith('> ')) line = line.substring(2).trim();
  // 标题变小节：只留标题文字。
  final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
  if (heading != null) return _stripInline(heading.group(2)!);
  // 列表符号变 ·。
  if (line.startsWith('- ') || line.startsWith('* ')) {
    return '· ${_stripInline(line.substring(2).trim())}';
  }
  return _stripInline(line);
}

/// 行内标记去掉：链接变文字、加粗/斜体/代码标记去掉。
String _stripInline(String text) {
  var out = text;
  // [文字](链接) → 文字；[文字][ref] → 文字。
  out = out.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (m) => m.group(1)!,
  );
  out = out.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\[[^\]]*\]'),
    (m) => m.group(1)!,
  );
  // `代码` → 代码；**加粗** / __加粗__ → 加粗；*斜体* / _斜体_ → 斜体。
  out = out.replaceAll('`', '');
  out = out.replaceAll('**', '').replaceAll('__', '');
  out = out.replaceAllMapped(
    RegExp(r'(^|\s)\*([^*]+)\*(?=\s|$)'),
    (m) => '${m.group(1)}${m.group(2)}',
  );
  out = out.replaceAllMapped(
    RegExp(r'(^|\s)_([^_]+)_(?=\s|$)'),
    (m) => '${m.group(1)}${m.group(2)}',
  );
  return out.trim();
}
