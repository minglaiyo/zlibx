import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Phase 2 timing baseline — the Dart twin of the Rust bench
/// (`rust/zlibx_parsers/src/fulltext.rs::bench_parse_50_hits`).
/// Both build the IDENTICAL 50-hit page, so the printed per-run
/// averages compare directly. Run with:
///   flutter test test/parsers/fulltext_bench_test.dart
/// (Rust side: cargo test bench_parse_50_hits -- --nocapture)
String _buildBenchPage50() {
  final buf = StringBuffer(
    '<html><body><div class="search-results-tabs-panel">'
    '<ul id="subprojectsSearch"><li class="active">'
    '全文检索&nbsp;(50)</li></ul></div>'
    '<div id="searchResultBox">',
  );
  for (var i = 0; i < 50; i++) {
    buf.write(
      '<div class="book-item"><div class="counter">${i + 1}</div>'
      '<z-bookcard id="${90000 + i}" '
      'termshash="t${i.toString().padLeft(32, '0')}" '
      'href="/book/BenchHash${i.toString().padLeft(2, '0')}/Bench-Book-$i.html" '
      'download="/dl/B$i" deleted="${i % 10 == 9 ? 9 : 0}" '
      'publisher="Bench Press" language="english" year="2020" '
      'extension="epub" filesize="1.00 MB" rating="4.0" quality="3" '
      'user_token="<redacted>" class="ready">'
      '<img data-src="https://example.com/covers100/bench-$i.png">'
      '<div slot="title">Bench Book $i</div>'
      '<div slot="author">Author $i</div>'
      '<div slot="extend"><div class="hulltext"><div class="ft_highlight">'
      '<div class="ft_highlight_part">plain lead <em>match $i</em> plain tail.</div>'
      '</div></div></div>'
      '</z-bookcard></div>',
    );
  }
  buf.write(
    '</div><script>var pagerOptions = {pagesTotal: 3, pagesSpan: 5};'
    '</script></body></html>',
  );
  return buf.toString();
}

void main() {
  test('bench: 50-hit page × 100 runs (Dart twin of the Rust bench)', () {
    final html = _buildBenchPage50();
    final warm = parseFullTextSearchPage(html);
    expect(warm.hits, hasLength(50));

    const n = 100;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final page = parseFullTextSearchPage(html);
      expect(page.hits, hasLength(50));
    }
    sw.stop();
    // ignore: avoid_print
    print(
      'BENCH dart: $n runs, ${sw.elapsedMilliseconds} ms total, '
      '${sw.elapsedMilliseconds / n} ms per run (50-hit page)',
    );
  });
}
