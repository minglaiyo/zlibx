import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/hive_service.dart';
import '../services/view_history_storage.dart';


/// 搜索建议（方案 D1）：输入时从本地数据出 typeahead，不发网络。
///
/// 两个来源、三档排序：
/// 1. 最近搜索关键词（Hive `recent_search_keywords`，与搜索页空态
///    的 chips 同源）——前缀匹配优先，其次包含；
/// 2. 浏览历史书名（Hive `view_history`，最近浏览的优先）；
/// 3. 浏览历史作者。
///
/// 全部纯客户端匹配（大小写不敏感的包含），最多 6 条，命中项本身
/// （与输入完全相同）不重复给出。无痕模式不新增记录但旧数据照常
/// 可见——与浏览历史页的语义一致。
class SearchSuggestion {
  const SearchSuggestion({required this.text, required this.fromHistory});

  final String text;

  /// true = 来自浏览历史（书名/作者，图标用书）；false = 来自最近
  /// 搜索关键词（图标用时钟）。
  final bool fromHistory;
}

final searchSuggestionsProvider =
    Provider.family<List<SearchSuggestion>, String>((ref, rawQuery) {
      final query = rawQuery.trim().toLowerCase();
      if (query.isEmpty) return const [];

      final suggestions = <SearchSuggestion>[];
      final seen = <String>{query};

      void add(String text, bool fromHistory, {required bool prefix}) {
        final trimmed = text.trim();
        final key = trimmed.toLowerCase();
        if (trimmed.isEmpty) return;
        // 先按本档过滤、再去重：去重发生在过滤之前会把前缀档拒绝过
        // 的候选烧进 seen，包含档就永远轮不到它（测试抓到的真 bug）。
        if (prefix ? !key.startsWith(query) : !key.contains(query)) return;
        if (!seen.add(key)) return;
        suggestions.add(
          SearchSuggestion(text: trimmed, fromHistory: fromHistory),
        );
      }

      // 最近搜索关键词（新 → 旧）。
      final saved = HiveService.settingsBox.get('recent_search_keywords');
      if (saved is List) {
        final keywords = saved
            .whereType<String>()
            .map((keyword) => keyword.trim())
            .where((keyword) => keyword.isNotEmpty)
            .toList();
        for (final keyword in keywords) {
          add(keyword, false, prefix: true);
        }
        for (final keyword in keywords) {
          add(keyword, false, prefix: false);
        }
      }

      // 浏览历史（最近 → 久远）：书名一档，作者一档。
      final history = ViewHistoryStore.entries();
      for (final entry in history) {
        if (entry.book.title.isNotEmpty) {
          add(entry.book.title, true, prefix: true);
        }
      }
      for (final entry in history) {
        final author = entry.book.author;
        if (author != null && author.isNotEmpty) {
          add(author, true, prefix: true);
        }
      }
      for (final entry in history) {
        if (entry.book.title.isNotEmpty) {
          add(entry.book.title, true, prefix: false);
        }
      }
      for (final entry in history) {
        final author = entry.book.author;
        if (author != null && author.isNotEmpty) {
          add(author, true, prefix: false);
        }
      }

      return suggestions.take(6).toList();
    });
