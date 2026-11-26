import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/constants/search_filters.dart';
import 'package:zlibx/providers/search_filter_options_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';

// Search-filter-options tests (plan item 6): server candidates merge
// over the hardcoded tables, the answers are cached for 7 days, and
// any fetch failure falls back to the hardcoded tables (or a stale
// cache when one exists).

class _FakeApi implements ZLibraryApi {
  Future<ApiResponse<Map<String, String>>> Function()? languagesAnswer;
  Future<ApiResponse<List<String>>> Function()? extensionsAnswer;
  int languagesCalls = 0;
  int extensionsCalls = 0;

  @override
  Future<ApiResponse<Map<String, String>>> getInfoLanguages() async {
    languagesCalls++;
    return languagesAnswer!();
  }

  @override
  Future<ApiResponse<List<String>>> getInfoExtensions() async {
    extensionsCalls++;
    return extensionsAnswer!();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'search_filter_options_test',
    );
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });
  setUp(() => Hive.box(HiveService.settingsBoxName).clear());
  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('mergeSearchFilterOptions', () {
    test('server-only codes are appended, local entries win', () {
      final merged = mergeSearchFilterOptions(
        serverLanguages: {
          'english': 'ENGLISH!',
          'klingon': 'Klingon',
          'Bad Code': 'Bad',
          'a b': 'Spaced',
          '': 'Empty',
        },
        serverExtensions: ['cbz', 'EPUB', 'c b z', ''],
      );
      // A local entry keeps its translations and API value.
      expect(merged.languages['english']!.en, 'English');
      expect(merged.languageApiValues['english'], 'english');
      // A server-only language is appended with the server's name.
      expect(merged.languages['klingon']!.en, 'Klingon');
      expect(merged.languages['klingon']!.apiValue, 'klingon');
      expect(merged.languageApiValues['klingon'], 'klingon');
      // Invalid codes never reach the UI.
      expect(merged.languages.containsKey('Bad Code'), isFalse);
      expect(merged.languages.containsKey('a b'), isFalse);
      expect(merged.languages.containsKey(''), isFalse);
      // A server-only extension is appended; the local 'epub' stays.
      expect(merged.extensions['cbz'], 'cbz');
      expect(merged.extensions['epub'], 'epub');
      expect(merged.extensions.containsKey('c b z'), isFalse);
      // Local order is kept, server-only codes go last.
      expect(
        merged.languages.keys.last,
        'klingon',
      );
      expect(merged.extensions.keys.last, 'cbz');
    });
  });

  group('searchFilterOptionsProvider', () {
    ProviderContainer _container(_FakeApi api) {
      final container = ProviderContainer(
        overrides: [zlibraryApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('fetches once, merges, and caches the answers', () async {
      final api = _FakeApi()
        ..languagesAnswer = () async =>
            ApiResponse.ok({'klingon': 'Klingon'})
        ..extensionsAnswer = () async => ApiResponse.ok(['cbz']);
      final container = _container(api);
      final options = await container.read(
        searchFilterOptionsProvider.future,
      );
      expect(options.languages.containsKey('klingon'), isTrue);
      expect(options.extensions.containsKey('cbz'), isTrue);
      // A second read reuses the provider's cached value: no refetch.
      final again = container.read(searchFilterOptionsProvider).valueOrNull;
      expect(again, isNotNull);
      expect(api.languagesCalls, 1);
      expect(api.extensionsCalls, 1);
      // And the answers are in the settings box for the next run.
      final cached =
          Hive.box(HiveService.settingsBoxName).get('search_filter_options');
      expect(cached, isA<Map>());
      expect(cached['languages']['klingon'], 'Klingon');
      expect(cached['extensions'], contains('cbz'));
    });

    test('fetch failure falls back to the hardcoded tables', () async {
      final api = _FakeApi()
        ..languagesAnswer = () async =>
            ApiResponse.fail('Access denied')
        ..extensionsAnswer = () async => ApiResponse.fail('Access denied');
      final container = _container(api);
      final options = await container.read(
        searchFilterOptionsProvider.future,
      );
      expect(
        options.languages.keys,
        containsAll(searchLanguageOptions.keys),
      );
      expect(options.languages.containsKey('klingon'), isFalse);
      expect(options.extensions.keys, searchExtensions.keys);
    });

    test('a fresh cache is used without fetching', () async {
      final box = Hive.box(HiveService.settingsBoxName);
      await box.put('search_filter_options', {
        'at': DateTime.now().millisecondsSinceEpoch,
        'languages': {'klingon': 'Klingon'},
        'extensions': ['cbz'],
      });
      final api = _FakeApi()
        ..languagesAnswer = () async => throw StateError('must not fetch')
        ..extensionsAnswer = () async => throw StateError('must not fetch');
      final container = _container(api);
      final options = await container.read(
        searchFilterOptionsProvider.future,
      );
      expect(options.languages.containsKey('klingon'), isTrue);
      expect(options.extensions.containsKey('cbz'), isTrue);
      expect(api.languagesCalls, 0);
      expect(api.extensionsCalls, 0);
    });

    test('a stale cache is used when the fetch fails', () async {
      final box = Hive.box(HiveService.settingsBoxName);
      await box.put('search_filter_options', {
        'at': DateTime.now().millisecondsSinceEpoch -
            const Duration(days: 8).inMilliseconds,
        'languages': {'klingon': 'Klingon'},
        'extensions': ['cbz'],
      });
      final api = _FakeApi()
        ..languagesAnswer = () async => ApiResponse.fail('offline')
        ..extensionsAnswer = () async => ApiResponse.fail('offline');
      final container = _container(api);
      final options = await container.read(
        searchFilterOptionsProvider.future,
      );
      expect(options.languages.containsKey('klingon'), isTrue);
      expect(options.extensions.containsKey('cbz'), isTrue);
    });
  });
}
