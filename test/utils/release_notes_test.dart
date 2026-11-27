import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/release_notes.dart';

/// 更新说明清洗（计划一第 16 项）：更新弹窗里只显示干净的更新内容，
/// 不显示 APK 文件名——截掉「## 下载」及之后的内容，去掉首行标题，
/// Markdown 转纯文本（链接变文字、去加粗/代码标记）。
void main() {
  group('sanitizeReleaseNotes', () {
    test('截掉「## 下载」段及之后的一切（APK 文件名）', () {
      const body = '''
# zlibx 1.8.0

## 新功能

- 新增 A
- 新增 B

## 下载

zlibx-v1.8.0.apk (36 MB)

## 修复

- 修了 C
''';
      expect(
        sanitizeReleaseNotes(body),
        '新功能\n\n· 新增 A\n· 新增 B',
      );
    });

    test('去掉首行标题，保留其余内容', () {
      expect(
        sanitizeReleaseNotes('# zlibx 1.8.0\n\n- 修了 X\n'),
        '· 修了 X',
      );
    });

    test('链接变文字、去加粗/代码/引用/分割线', () {
      const body = '''
# 标题

修复了 **[重要问题](https://example.com/issue/1)**，见 `foo.dart`。

> 附注一行

---
''';
      expect(
        sanitizeReleaseNotes(body),
        '修复了 重要问题，见 foo.dart。\n\n附注一行',
      );
    });

    test('## 小节去标记、- 列表改 ·', () {
      const body = '''
## 改进

- 第一项
- 第二项
''';
      expect(sanitizeReleaseNotes(body), '改进\n\n· 第一项\n· 第二项');
    });

    test('空正文 / 只有标题：返空串', () {
      expect(sanitizeReleaseNotes(''), '');
      expect(sanitizeReleaseNotes('# zlibx 1.8.0\n'), '');
      expect(sanitizeReleaseNotes('## 下载\n\nzlibx-v1.8.0.apk\n'), '');
    });

    test('没有标题行：内容原样过清洗', () {
      expect(
        sanitizeReleaseNotes('直接写的内容\n第二行\n'),
        '直接写的内容\n第二行',
      );
    });

    test('多余空行折叠、首尾空白去掉', () {
      expect(
        sanitizeReleaseNotes('\n\n\n# t\n\n\n\n- a\n\n\n- b\n\n\n'),
        '· a\n\n· b',
      );
    });
  });
}
