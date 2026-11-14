/// Z-Library API client + data models.
///
/// This is a clean-room rewrite built from the call sites in olib-mobile
/// (see README.md for the endpoint verification status of each method).
/// It intentionally exports only what the app imports:
/// [ZLibraryApi], [Book], [User], [BookComment] and [Booklist]
/// (plus [ApiResponse] and the like/comment result types).
library;

export 'src/api_response.dart';
export 'src/article_search.dart';
export 'src/book.dart';
export 'src/book_comment.dart';
export 'src/book_detail_extras.dart';
export 'src/book_detail_html.dart';
export 'src/booklist.dart';
export 'src/category.dart';
export 'src/download_range.dart';
export 'src/download_stats.dart';
export 'src/fulltext.dart';
export 'src/user.dart';
export 'src/zlibrary_api.dart';
