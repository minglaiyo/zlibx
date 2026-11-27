import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/article_search_provider.dart';
import 'package:zlibx/providers/author_books_provider.dart';
import 'package:zlibx/providers/cache_invalidation.dart';
import 'package:zlibx/providers/external_search_notifier.dart';
import 'package:zlibx/providers/fulltext_search_provider.dart';
import 'package:zlibx/providers/search_notifier.dart';

class _CountingSearchNotifier extends SearchNotifier {
  _CountingSearchNotifier(this.onBuild);

  final void Function() onBuild;

  @override
  SearchState build() {
    onBuild();
    return super.build();
  }
}

class _CountingArticleSearchNotifier extends ArticleSearchNotifier {
  _CountingArticleSearchNotifier(this.onBuild);

  final void Function() onBuild;

  @override
  ArticleSearchState build() {
    onBuild();
    return super.build();
  }
}

class _CountingFullTextSearchNotifier extends FullTextSearchNotifier {
  _CountingFullTextSearchNotifier(this.onBuild);

  final void Function() onBuild;

  @override
  FullTextSearchState build() {
    onBuild();
    return super.build();
  }
}

class _CountingExternalSearchNotifier extends ExternalSearchNotifier {
  _CountingExternalSearchNotifier(this.onBuild);

  final void Function() onBuild;

  @override
  ExternalSearchState build() {
    onBuild();
    return super.build();
  }
}

class _CountingAuthorBooksNotifier extends AuthorBooksNotifier {
  _CountingAuthorBooksNotifier(this.onBuild);

  final void Function() onBuild;

  @override
  AuthorBooksState build(String arg) {
    onBuild();
    return super.build(arg);
  }
}

void main() {
  test('换号/换线统一失效搜索与作者缓存', () {
    final builds = <String, int>{};
    void count(String name) {
      builds[name] = (builds[name] ?? 0) + 1;
    }

    final container = ProviderContainer(
      overrides: [
        searchProvider.overrideWith(
          () => _CountingSearchNotifier(() => count('search')),
        ),
        articleSearchProvider.overrideWith(
          () => _CountingArticleSearchNotifier(() => count('article')),
        ),
        fulltextSearchProvider.overrideWith(
          () => _CountingFullTextSearchNotifier(() => count('fulltext')),
        ),
        externalSearchProvider.overrideWith(
          () => _CountingExternalSearchNotifier(() => count('external')),
        ),
        authorBooksProvider.overrideWith(
          () => _CountingAuthorBooksNotifier(() => count('author')),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchProvider);
    container.read(articleSearchProvider);
    container.read(fulltextSearchProvider);
    container.read(externalSearchProvider);
    container.read(authorBooksProvider('author'));
    expect(builds, hasLength(5));
    expect(builds.values, everyElement(1));

    late Ref invalidationRef;
    final refHolder = Provider<void>((ref) => invalidationRef = ref);
    container.read(refHolder);
    invalidateAccountScopedProviders(invalidationRef);
    container.read(searchProvider);
    container.read(articleSearchProvider);
    container.read(fulltextSearchProvider);
    container.read(externalSearchProvider);
    container.read(authorBooksProvider('author'));

    expect(builds, hasLength(5));
    expect(builds.values, everyElement(2));
  });
}
