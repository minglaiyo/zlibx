/// Blocklist matching for search results.
///
/// A book is hidden when any blocked keyword appears as a
/// case-insensitive substring in its title, author or publisher.
/// Empty or blank keywords never match. There is no translator field
/// anywhere in the data (neither search results nor the detail page
/// carry one), so translator blocking is not possible from here.
bool isBlockedByKeywords({
  required String? title,
  required String? author,
  required String? publisher,
  required List<String> keywords,
}) {
  if (keywords.isEmpty) return false;
  final haystacks = <String>[
    if (title != null && title.isNotEmpty) title.toLowerCase(),
    if (author != null && author.isNotEmpty) author.toLowerCase(),
    if (publisher != null && publisher.isNotEmpty) publisher.toLowerCase(),
  ];
  if (haystacks.isEmpty) return false;
  for (final keyword in keywords) {
    final needle = keyword.trim().toLowerCase();
    if (needle.isEmpty) continue;
    for (final haystack in haystacks) {
      if (haystack.contains(needle)) return true;
    }
  }
  return false;
}
