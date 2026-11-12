import 'book_detail_html.dart';

/// Everything one book detail page carries beyond the eapi book
/// object, parsed from a single `GET /book/{hash}/{slug}.html` fetch:
/// the server-rendered metadata rows. `fetchBookDetailExtras` (in the
/// search mixin) returns this.
class BookDetailExtras {
  /// The `bookProperty` rows (volume / ISBN / IPFS / rating — see
  /// [parseBookDetailProperties]). May be all-null when the page has
  /// no property box.
  final BookDetailMetadata metadata;

  const BookDetailExtras({required this.metadata});
}
