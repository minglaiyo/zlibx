import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zlibx/utils/diagnostics.dart';
import '../services/hive_service.dart';
import 'domain_provider.dart';

enum DomainLatencyStatus { untested, normal, slow, unavailable }

/// A reachable line is healthy through 3000 ms. Higher latency is shown as a
/// warning, while only a failed request is treated as unavailable.
DomainLatencyStatus domainLatencyStatus(int? latencyMs) {
  if (latencyMs == null) return DomainLatencyStatus.untested;
  if (latencyMs < 0) return DomainLatencyStatus.unavailable;
  if (latencyMs <= 3000) return DomainLatencyStatus.normal;
  return DomainLatencyStatus.slow;
}

/// Result of a single domain speed test.
class DomainTestResult {
  final String domain;

  /// null = not tested, -1 = failed, >0 = latency in ms
  int? latencyMs;

  DomainTestResult(this.domain, {this.latencyMs});
}

/// State for the speed test provider.
class SpeedTestState {
  final List<DomainTestResult> results;
  final bool testing;
  final int testedCount;

  const SpeedTestState({
    this.results = const [],
    this.testing = false,
    this.testedCount = 0,
  });

  int get onlineCount =>
      results.where((r) => r.latencyMs != null && r.latencyMs! > 0).length;

  SpeedTestState copyWith({
    List<DomainTestResult>? results,
    bool? testing,
    int? testedCount,
  }) {
    return SpeedTestState(
      results: results ?? this.results,
      testing: testing ?? this.testing,
      testedCount: testedCount ?? this.testedCount,
    );
  }
}

class SpeedTestNotifier extends Notifier<SpeedTestState> {
  // Reassignable, not `late final`: build() re-runs when the domain
  // list changes (SLUM data arriving) and a second late-final
  // assignment would throw LateInitializationError — the same trap
  // documented on DomainNotifier's _api.
  List<String> _domains = const [];

  /// Max concurrent requests to avoid flooding the network. Four at a
  /// time is enough to rank the lines quickly without hammering the
  /// mirrors (O3: was 8).
  static const int _maxConcurrent = 4;

  /// Last speed-test result, persisted in the Hive settings box so a
  /// cold start does not re-test every mirror (O3). The cache is only
  /// reused while fresh AND while it covers every current domain: a
  /// new SLUM line (not in the cache) forces a full test, so a new
  /// line is never hidden behind a stale ranking.
  static const String _cacheKey = 'speed_test_cache';
  static const Duration _cacheTtl = Duration(hours: 12);

  /// Restore the cached result into [state] and return true when the
  /// cache is fresh and covers every current domain. No network is
  /// touched on the restore path. Returns false (state untouched) when
  /// there is no cache, it is stale, it does not cover all domains, or
  /// the stored value is malformed.
  bool _restoreFromCache() {
    if (_domains.isEmpty) return false;
    try {
      final raw = HiveService.settingsBox.get(_cacheKey);
      if (raw is! String) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      final timestamp = decoded['timestamp'];
      if (timestamp is! int) return false;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(savedAt) > _cacheTtl) return false;
      final resultsJson = decoded['results'];
      if (resultsJson is! Map<String, dynamic>) return false;
      final cached = <DomainTestResult>[];
      for (final domain in _domains) {
        final latency = resultsJson[domain];
        if (latency is! int) return false;
        cached.add(DomainTestResult(domain, latencyMs: latency));
      }
      // The cache was saved in ranked order (fastest first), so the
      // picker shows the best lines immediately on cold start.
      state = SpeedTestState(
        results: cached,
        testing: false,
        testedCount: cached.length,
      );
      return true;
    } on Object catch (e) {
      // A corrupt cache must never block the speed test — fall through
      // to a full test (the fresh result overwrites the bad value).
      logIgnored('speed_test_provider', e);
      return false;
    }
  }

  /// Persist the ranked [results] for the next cold start.
  void _saveToCache(List<DomainTestResult> results) {
    try {
      HiveService.settingsBox.put(
        _cacheKey,
        jsonEncode({
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'results': {
            for (final r in results) r.domain: r.latencyMs ?? -1,
          },
        }),
      );
    } on Object catch (e) {
      // Caching is best-effort: a failed write must not fail the test.
      logIgnored('speed_test_provider', e);
    }
  }

  @override
  SpeedTestState build() {
    final domains = ref.watch(domainListProvider);
    // A test in flight must not be clobbered by a list change: keep
    // its results. The new list is picked up by runTest(), which
    // re-runs when it notices the list moved mid-test (see below).
    final prev = stateOrNull;
    if (prev != null && prev.testing) {
      _domains = domains;
      return prev;
    }
    // The list moved (SLUM data arrived) while no test was in flight:
    // re-run against the new list, otherwise the picker would sit on
    // untested rows until the user taps Retest. Skipped on first build
    // (_domains empty) — the splash screen starts the first test, and
    // runTest()'s testing guard makes a duplicate call a no-op anyway.
    // The microtask runs after build() returns, when the notifier is
    // initialized; setting state there does not re-trigger build().
    if (_domains.isNotEmpty && !_sameDomains(_domains, domains)) {
      _domains = domains;
      Future.microtask(runTest);
    } else {
      _domains = domains;
    }
    // Was _initResults(): the initial results list is the initial state
    // itself (a state assignment inside build() would be overwritten by
    // its return value).
    return SpeedTestState(
      results: _domains.map((d) => DomainTestResult(d)).toList(),
    );
  }

  /// Run speed test with bounded concurrency (semaphore pattern).
  /// Safe to call multiple times — ignores if already running.
  ///
  /// Cold start reuses the last result for [_cacheTtl] when it covers
  /// every current domain (O3) — no network. [force] (the mirror
  /// page's Retest button) always runs a fresh full test; [isRetry] is
  /// the internal re-run after the domain list moved mid-test.
  Future<void> runTest({bool force = false, bool isRetry = false}) async {
    if (state.testing) return;

    // Fresh cache: paint the ranked lines immediately, no network.
    if (!force && !isRetry && _restoreFromCache()) return;

    // Reset results
    final results = _domains.map((d) => DomainTestResult(d)).toList();
    // The list this run tests. If the domain list changes while the
    // test runs (SLUM data arriving), these results are for a stale
    // list — the check at the end discards them and re-runs against
    // the new list instead of publishing results that would hide the
    // new SLUM lines from the picker.
    final testedDomains = List<String>.from(_domains);
    state = SpeedTestState(results: results, testing: true, testedCount: 0);

    int running = 0;
    int index = 0;
    int tested = 0;
    final completer = Completer<void>();

    void scheduleNext() {
      while (running < _maxConcurrent && index < results.length) {
        final r = results[index++];
        running++;
        _checkDomain(r).whenComplete(() {
          running--;
          tested++;
          state = state.copyWith(
            results: List.from(results),
            testedCount: tested,
          );
          if (index < results.length) {
            scheduleNext();
          } else if (running == 0) {
            completer.complete();
          }
        });
      }
    }

    scheduleNext();
    await completer.future;

    // Sort: successful (ascending latency) first, then failed at bottom.
    results.sort((a, b) {
      final la = a.latencyMs ?? 99999;
      final lb = b.latencyMs ?? 99999;
      final aOk = la > 0 && la < 99999;
      final bOk = lb > 0 && lb < 99999;
      if (aOk && !bOk) return -1;
      if (!aOk && bOk) return 1;
      return la.compareTo(lb);
    });

    // The domain list moved while this run was in flight (SLUM data
    // arrived): these results are for a stale list. Discard them and
    // re-run against the current list. Bounded to one retry — the list
    // only changes when SLUM data arrives, so a second move mid-retry
    // is not expected; the retry's results stand in that case.
    if (!isRetry && !_sameDomains(testedDomains, ref.read(domainListProvider))) {
      _domains = ref.read(domainListProvider);
      state = SpeedTestState(
        results: _domains.map((d) => DomainTestResult(d)).toList(),
        testing: false,
        testedCount: 0,
      );
      return runTest(isRetry: true);
    }

    // Only the final (published) run is cached: the discarded first
    // run above returns before this line, so a stale ranking never
    // overwrites a fresh one.
    _saveToCache(results);

    state = SpeedTestState(
      results: List.from(results),
      testing: false,
      testedCount: tested,
    );
  }

  static bool _sameDomains(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _checkDomain(DomainTestResult result) async {
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse('https://${result.domain}/eapi/info/languages');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);

      try {
        final request = await client.getUrl(uri);
        // Headers are enough: the ranking only needs time-to-first-byte,
        // not the whole languages page. (Previously the full body was
        // read and a non-2xx page counted as success when its body
        // contained '"success":1'; that exotic case no longer counts —
        // a healthy mirror answers this endpoint 2xx.)
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        sw.stop();

        final isSuccess =
            response.statusCode >= 200 && response.statusCode < 300;

        result.latencyMs = isSuccess ? sw.elapsedMilliseconds : -1;
      } catch (error) {
        logIgnored('speed_test_provider', error);
        sw.stop();
        result.latencyMs = -1;
      } finally {
        // force: the response body was never read — drop the connection
        // now instead of waiting for the server to finish sending it.
        client.close(force: true);
      }
    } catch (error) {
      logIgnored('speed_test_provider', error);
      sw.stop();
      result.latencyMs = -1;
    }
  }
}

/// Global speed test state — cached across the app lifecycle.
final speedTestProvider =
    NotifierProvider<SpeedTestNotifier, SpeedTestState>(SpeedTestNotifier.new);
