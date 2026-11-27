import '../../services/hive_service.dart';

/// Recent-search keywords for the search screen (P1-4 split of
/// search_screen.dart): Hive persistence + the de-dup/limit rules.
/// The screen still owns the setState/snackbar shell around saving;
/// this class owns the list and the storage rules.
class RecentSearchesStore {
  static const String _key = 'recent_search_keywords';
  static const int _limit = 12;

  List<String> searches = [];

  /// Load the saved keywords (sync Hive read).
  void load() {
    searches = normalize(HiveService.settingsBox.get(_key));
  }

  /// De-dup (case-insensitive, first occurrence wins) + trim + limit.
  static List<String> normalize(Object? saved) {
    if (saved is! List) return [];
    final seen = <String>{};
    return saved
        .whereType<String>()
        .map((keyword) => keyword.trim())
        .where(
          (keyword) => keyword.isNotEmpty && seen.add(keyword.toLowerCase()),
        )
        .take(_limit)
        .toList();
  }

  /// The list after remembering [query] (newest first, de-duplicated
  /// case-insensitively, capped at [_limit]).
  List<String> remembered(String query) {
    final normalized = query.toLowerCase();
    return [
      query,
      ...searches.where((item) => item.toLowerCase() != normalized),
    ].take(_limit).toList();
  }

  /// The list without [keyword].
  List<String> without(String keyword) =>
      searches.where((item) => item != keyword).toList();

  /// Persist the current list to Hive.
  Future<void> persist() => HiveService.settingsBox.put(_key, searches);
}
