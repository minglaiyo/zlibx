import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/unified_shelf_item.dart';
import '../services/hive_service.dart';
import '../utils/app_log.dart';

class ShelfCategory {
  const ShelfCategory({required this.id, required this.name});

  final String id;
  final String name;
}

class ShelfCategoriesState {
  const ShelfCategoriesState(this.categories, this.assignments);

  final List<ShelfCategory> categories;
  final Map<String, String> assignments;

  String? categoryFor(UnifiedShelfItem item) => assignments[item.categoryKey];

  int countFor(String categoryId, Iterable<UnifiedShelfItem> items) =>
      items.where((item) => categoryFor(item) == categoryId).length;
}

class ShelfCategoriesNotifier extends Notifier<ShelfCategoriesState> {
  @override
  ShelfCategoriesState build() => _load();

  static const _storageKey = 'shelf_categories_v1';

  static ShelfCategoriesState _load() {
    final raw = HiveService.settingsBox.get(_storageKey);
    if (raw is! String) return const ShelfCategoriesState([], {});
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final categories = (data['categories'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(
            (value) => ShelfCategory(
              id: value['id'].toString(),
              name: value['name'].toString(),
            ),
          )
          .toList();
      final assignments =
          (data['assignments'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          <String, String>{};
      return ShelfCategoriesState(categories, assignments);
    } catch (error) {
      AppLog.report(
        'Could not load shelf categories: ${error.runtimeType}',
        tag: 'shelf_categories',
      );
      return const ShelfCategoriesState([], {});
    }
  }

  Future<void> _save(ShelfCategoriesState next) async {
    // Publish the new state BEFORE awaiting the disk write: computing
    // each change from `state` (see create/rename/assign), a second
    // change fired while the first was still awaiting Hive would read
    // the OLD state and overwrite the first change's result (a freshly
    // created category silently disappeared).
    state = next;
    final data = jsonEncode({
      'categories': [
        for (final category in next.categories)
          {'id': category.id, 'name': category.name},
      ],
      'assignments': next.assignments,
    });
    try {
      await HiveService.settingsBox.put(_storageKey, data);
    } catch (error) {
      // Persistence failure must not lose the in-memory change; the next
      // successful save rewrites the whole blob anyway.
      AppLog.report(
        'Could not persist shelf categories: ${error.runtimeType}',
        tag: 'shelf_categories',
      );
    }
  }

  Future<void> create(String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty ||
        state.categories.any(
          (category) => category.name.toLowerCase() == cleaned.toLowerCase(),
        )) {
      throw ArgumentError('Duplicate or empty category');
    }
    await _save(
      ShelfCategoriesState([
        ...state.categories,
        ShelfCategory(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: cleaned,
        ),
      ], state.assignments),
    );
  }

  Future<void> rename(String id, String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty ||
        state.categories.any(
          (category) =>
              category.id != id &&
              category.name.toLowerCase() == cleaned.toLowerCase(),
        )) {
      throw ArgumentError('Duplicate or empty category');
    }
    await _save(
      ShelfCategoriesState([
        for (final category in state.categories)
          category.id == id ? ShelfCategory(id: id, name: cleaned) : category,
      ], state.assignments),
    );
  }

  Future<void> delete(String id) async {
    await _save(
      ShelfCategoriesState(
        state.categories.where((category) => category.id != id).toList(),
        Map.of(state.assignments)..removeWhere((_, value) => value == id),
      ),
    );
  }

  Future<void> assign(
    Iterable<UnifiedShelfItem> items,
    String? categoryId,
  ) async {
    if (categoryId != null &&
        !state.categories.any((category) => category.id == categoryId)) {
      throw ArgumentError('Unknown category');
    }
    final assignments = Map<String, String>.of(state.assignments);
    for (final item in items) {
      if (categoryId == null) {
        assignments.remove(item.categoryKey);
      } else {
        assignments[item.categoryKey] = categoryId;
      }
    }
    await _save(ShelfCategoriesState(state.categories, assignments));
  }
}

final shelfCategoriesProvider =
    NotifierProvider<ShelfCategoriesNotifier, ShelfCategoriesState>(
      ShelfCategoriesNotifier.new,
    );
