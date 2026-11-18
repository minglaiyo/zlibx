// Open Library trending feed (public API, no login) for the search
// screen's discovery section. Plain FutureProvider: the list is fetched
// once per app session and cached; a failure yields an empty list and
// the section hides itself.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/open_library.dart';

final trendingBooksProvider = FutureProvider<List<TrendingBookData>>((
  ref,
) async {
  return OpenLibrary().trendingBooks();
});
