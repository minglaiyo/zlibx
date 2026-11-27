// Anna's Archive result models, split out of annas_archive_service.dart so the
// service file stays readable. Re-exported by annas_archive_service.dart: the
// seven importers keep seeing BookData / BookInfoData unchanged.

class BookData {
  final String title;
  final String? author;
  final String? thumbnail;
  final String link;
  final String md5;
  final String? publisher;
  final String? info;

  /// Which catalog produced this result, for UI labelling. Null on
  /// records that predate tagging (trending rows, older caches).
  final String? source;

  BookData({
    required this.title,
    this.author,
    this.thumbnail,
    required this.link,
    required this.md5,
    this.publisher,
    this.info,
    this.source,
  });

  BookData copyWith({String? source, String? thumbnail}) => BookData(
    title: title,
    author: author,
    thumbnail: thumbnail ?? this.thumbnail,
    link: link,
    md5: md5,
    publisher: publisher,
    info: info,
    source: source ?? this.source,
  );
}

class BookInfoData extends BookData {
  String? mirror;
  final String? description;
  final String? format;
  bool isFastDownload;

  BookInfoData({
    required super.title,
    required super.author,
    required super.thumbnail,
    required super.publisher,
    required super.info,
    required super.link,
    required super.md5,
    required this.format,
    required this.mirror,
    required this.description,
    this.isFastDownload = false,
  });
}
