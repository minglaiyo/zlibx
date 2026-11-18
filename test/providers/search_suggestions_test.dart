import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/search_suggestions_provider.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/view_history_storage.dart';

/// 搜索建议（方案 D1）：最近搜索关键词 + 浏览历史的排序与去重。
/// 普通 test() + 真实 Hive 临时目录（testWidgets 区里不能 await Hive
/// 写操作，见 settings_privacy_incognito_test 的教训）。
Directory? _hiveDir;

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('search_suggest_test');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.viewHistoryBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveDir!.delete(recursive: true);
  });

  List<String> suggestionsFor(String query) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container
        .read(searchSuggestionsProvider(query))
        .map((suggestion) => suggestion.text)
        .toList();
  }

  test('空查询不给建议', () {
    expect(suggestionsFor('  '), isEmpty);
  });

  test('最近关键词：前缀匹配优先于包含匹配', () async {
    await HiveService.settingsBox.put('recent_search_keywords', [
      'harry potter',
      'harry',
      'the harry theory',
    ]);
    // 命中项本身（与输入完全相同）不重复给出。
    final result = suggestionsFor('harry');
    expect(result.first, 'harry potter');
    expect(result, isNot(contains('harry')));
    expect(result, contains('the harry theory'));
  });

  test('浏览历史书名/作者参与建议，作者兜底在书名后', () async {
    await HiveService.settingsBox.put('recent_search_keywords', []);
    ViewHistoryStore.add(
      Book(id: 1, title: 'Machine Learning Yearning', author: 'Andrew Ng'),
    );
    ViewHistoryStore.add(
      Book(id: 2, title: 'Deep Learning', author: 'Ian Goodfellow'),
    );

    final result = suggestionsFor('learning');
    // 两个书名都在；作者 "Ian Goodfellow"/"Andrew Ng" 不含 learning，
    // 不出现。
    expect(result, contains('Machine Learning Yearning'));
    expect(result, contains('Deep Learning'));
    expect(result, hasLength(2));

    final byAuthor = suggestionsFor('goodfellow');
    expect(byAuthor, contains('Ian Goodfellow'));
  });

  test('上限 6 条：超出的低优先档被截断', () async {
    await HiveService.settingsBox.put('recent_search_keywords', [
      'data 1',
      'data 2',
      'data 3',
    ]);
    ViewHistoryStore.add(Book(id: 3, title: 'data A'));
    ViewHistoryStore.add(Book(id: 4, title: 'data B'));
    ViewHistoryStore.add(Book(id: 5, title: 'data C'));
    ViewHistoryStore.add(Book(id: 6, title: 'data D'));
    final result = suggestionsFor('data');
    expect(result, hasLength(6));
    // 前缀档全在前三。
    expect(result.take(3), containsAll(['data 1', 'data 2', 'data 3']));
  });
}
