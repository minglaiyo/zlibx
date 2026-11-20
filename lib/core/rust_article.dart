import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart' as zl;
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
import 'rust_init.dart';

/// Phase 3: wires the Rust-backed article search parser into the
/// vendor plugin's `articleParseOverride` hook. Same architecture as
/// rust_fulltext.dart: lazy FRB init (never blocks startup, silently
/// falls back to Dart when the bridge is unavailable), and a model
/// mapping layer to the hand-written vendor models.
///
/// Call [injectRustArticleParser] once from `main()`.
void injectRustArticleParser() {
  zl.articleParseOverride = _rustParseArticle;
}

Future<zl.ArticleSearchPage> _rustParseArticle(
  String html,
  String? baseUrl,
) async {
  try {
    await ensureRustBridge();
  } on Object catch (e) {
    if (kDebugMode) {
      logIgnored('frb_article_init', e);
    }
    zl.articleParseOverride = null;
    return zl.parseArticleSearchPage(html, baseUrl: baseUrl);
  }
  final page = await frb_api.parseArticleSearchPage(
    html: html,
    baseUrl: baseUrl ?? '',
  );
  if (kDebugMode) {
    AppLog.debug(
      'article parsed via Rust: ${page.articles.length} hits, '
      'total ${page.total}, pages ${page.totalPages}',
      tag: 'FRB',
    );
  }
  return _mapArticlePage(page);
}

zl.ArticleSearchPage _mapArticlePage(frb.ArticleSearchPage page) {
  return zl.ArticleSearchPage(
    articles: page.articles.map(_mapArticle).toList(),
    total: page.total,
    totalPages: page.totalPages,
  );
}

zl.Article _mapArticle(frb.Article a) {
  return zl.Article(
    id: a.id,
    title: a.title,
    href: a.href,
    url: a.url,
    hash: a.hash,
    author: a.author,
    cover: a.cover,
    publisher: a.publisher,
    year: a.year,
    language: a.language,
    // FRB renames `extension` (Dart reserved word) to `extension_`.
    extension: a.extension_,
    filesizeString: a.filesizeString,
    rating: a.rating,
    quality: a.quality,
    downloadPath: a.downloadPath,
    removed: a.removed,
    unavailableReason: a.unavailableReason,
  );
}
