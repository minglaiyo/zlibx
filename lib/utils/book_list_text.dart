/// 文本清单（#101：书单导出/分享，推广到收藏/图书馆）。
///
/// 排版 D（用户 2026-11-23 选定）：标题（N 本）+ 分隔线 + 一本书一行，
/// 每行：书名 — 作者 — 年份，缺的省掉。z 站书单的链接附在末尾。
///
/// 每本书是 (title, author, year) 的记录：z 站 Book 的 year 是
/// int，DisplayBook 的年份在 tagExtra（z 站书是年份字符串，
/// Anna/LibGen 没有年份所以是 null）——调用方统一转成 String 传进来。
String buildBookListText({
  required String title,
  required List<({String title, String? author, String? year})> books,
  String? link,
}) {
  final buffer = StringBuffer('$title（${books.length} 本）\n─────');
  for (final book in books) {
    buffer.write('\n${book.title}');
    final author = book.author?.trim();
    if (author != null && author.isNotEmpty) buffer.write(' — $author');
    final year = book.year?.trim();
    if (year != null && year.isNotEmpty) buffer.write(' — $year');
  }
  final cleanLink = link?.trim();
  if (cleanLink != null && cleanLink.isNotEmpty) {
    buffer.write('\n$cleanLink');
  }
  return buffer.toString();
}
