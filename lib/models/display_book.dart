import 'package:olib_api_plugin/olib_api_plugin.dart';

// Project imports:
import '../core/annas_archive.dart';
import '../services/annas_archieve.dart';

/// 数据源标识
enum BookSource { zlibrary, annasArchive, libgen }

/// 统一书籍展示模型
///
/// 解耦 UI 组件（BookCard / BookListTile / BookHeroSection）与具体数据源。
/// 通过 [Book.toDisplay] extension 方法创建。
class DisplayBook {
  final String id;
  final String title;
  final String? author;
  final String? cover;

  /// 卡片左上标签（z站: 格式 "EPUB"）
  final String? tag;

  /// 卡片顶部辅助标签（z站: 年份）
  final String? tagExtra;

  /// 评分/兴趣分（z站: interestScore）
  final String? score;

  /// 详情页评分角标文本（站内 interest / quality 形态），无评分时 null。
  /// 由 [BookToDisplay] 从 ratingInterest / ratingQuality 算出。
  final String? ratingText;

  /// 卡片底部右侧辅助文本（z站=文件大小）
  final String? meta;

  /// 详情页简介
  final String? description;

  /// 出版社
  final String? publisher;

  /// 数据来源
  final BookSource source;

  /// 原始对象引用 — 用于路由传参等类型特定操作
  final dynamic original;

  const DisplayBook({
    required this.id,
    required this.title,
    this.author,
    this.cover,
    this.tag,
    this.tagExtra,
    this.score,
    this.ratingText,
    this.meta,
    this.description,
    this.publisher,
    required this.source,
    this.original,
  });

  /// 是否来自 z站
  bool get isZLibrary => source == BookSource.zlibrary;

  /// 是否来自 Anna's Archive
  bool get isAnnasArchive => source == BookSource.annasArchive;

  /// 是否来自 LibGen
  bool get isLibGen => source == BookSource.libgen;

  /// 获取原始 z站 Book 对象（仅当 source == zlibrary 时有效）
  Book? get asZLibBook => isZLibrary ? original as Book? : null;

  /// 获取原始 Anna's Archive BookData（仅当 source == annasArchive 时有效）
  BookData? get asAnnaBookData =>
      isAnnasArchive ? original as BookData? : null;

  /// 获取原始 LibGen BookData（仅当 source == libgen 时有效）
  BookData? get asLibgenBookData => isLibGen ? original as BookData? : null;

}

// ═══════════════════════════════════════════════════════════════════
// Extension 适配器
// ═══════════════════════════════════════════════════════════════════

/// 站内详情页的 `interest / quality` 评分文本；缺一边就只显示有的一边，
/// 两边都没有时为 null（不显示角标）。
String? _detailRatingText(Book book) {
  final interest = book.ratingInterest;
  final quality = book.ratingQuality;
  if (interest != null &&
      interest.isNotEmpty &&
      quality != null &&
      quality.isNotEmpty) {
    return '$interest / $quality';
  }
  if (interest != null && interest.isNotEmpty) return interest;
  if (quality != null && quality.isNotEmpty) return quality;
  return null;
}

/// z站 Book → DisplayBook
extension BookToDisplay on Book {
  DisplayBook toDisplay() => DisplayBook(
    id: id.toString(),
    title: title,
    author: author,
    cover: cover,
    tag: extension != null && extension!.isNotEmpty
        ? extension!.toUpperCase()
        : null,
    tagExtra: (year != null && year != 0) ? '$year' : null,
    score: interestScore,
    ratingText: _detailRatingText(this),
    meta: filesizeString,
    description: description,
    publisher: publisher,
    source: BookSource.zlibrary,
    original: this,
  );
}

/// Anna's Archive BookData → DisplayBook.
///
/// Named toAnnaDisplayBook (not toDisplay) on purpose: the z站 Book
/// extension above already provides toDisplay(), and sharing that name
/// made the call sites ambiguous. id 是 md5（十六进制字符串，不再二次哈希）；
/// 详情页用它取 BookInfoData，下载（Stage 3）用它前 8 位十六进制转 int 作
/// DownloadTask 的键。tag 是从 info 列解析出的格式标签（如 "EPUB"）；
/// BookData 没有年份和评分，简介/出版社/文件大小只在详情页的 BookInfoData 里才有。
extension BookDataToDisplay on BookData {
  DisplayBook toAnnaDisplayBook() => DisplayBook(
    id: md5,
    title: title,
    author: author,
    cover: thumbnail,
    tag: ArchiveParsing.formatFromInfo(info),
    source: BookSource.annasArchive,
    original: this,
  );

  /// LibGen BookData → DisplayBook. Same shape as Anna's: id is the md5
  /// (or, when the search row carried no md5 link, the edition id or the
  /// title — see LibgenProvider). Search rows carry no thumbnail, so the
  /// cover stays null until the detail page parses one from ads.php.
  DisplayBook toLibgenDisplayBook() => DisplayBook(
    id: md5,
    title: title,
    author: author,
    cover: thumbnail,
    tag: ArchiveParsing.formatFromInfo(info),
    source: BookSource.libgen,
    original: this,
  );
}
