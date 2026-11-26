// Device-side mirror speed test.
//
// SLUM's latency is measured by open-slum.org's server, not from this
// phone — through a VPN the ranking can be completely different. This
// probes each enabled mirror from the device and ranks mirrors by the
// measured time, so downloads try the fastest mirror for *this*
// network first.
//
// The probe itself is [DomainProbe] (plan item 4): it follows the
// mirror's redirects by hand (max 3 hops) and tells a wall, a loop
// and a hop to another domain apart, instead of the old auto-follow
// GET that lumped all three into "failed". A mirror that ends at a
// live page — or at a verified redirect target — counts with its time
// to the terminal response; anything else is unranked.
//
// Only the LibGen download path uses the ranking ([rankedUrls]);
// search keeps SLUM order. Results are cached for [cacheTtl]; the
// Mirrors page runs the probe on demand and shows the measured time
// next to SLUM's latency.
import 'dart:async';

import 'package:dio/dio.dart';

import '../utils/app_log.dart';
import 'domain_probe.dart';
import 'hive_service.dart';
import 'http_client.dart';
import 'instance_manager.dart';


class MirrorSpeedTest {
  MirrorSpeedTest({Dio? dio})
    : _dio =
          dio ??
          createDio(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
          );

  final Dio _dio;

  static const Duration cacheTtl = Duration(hours: 1);

  String _cacheKey(MirrorService service) => 'mirror_speed_${service.name}';

  /// Measured milliseconds per host from the last probe, or null when
  /// never probed or stale.
  Map<String, int>? cachedMs(MirrorService service) {
    final raw = HiveService.settingsBox.get(_cacheKey(service));
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! int) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > cacheTtl.inMilliseconds) {
      return null;
    }
    final ms = raw['ms'];
    if (ms is! Map) return null;
    return {
      for (final entry in ms.entries)
        entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  /// In-flight probes, one per service: a second caller (double-tap
  /// on the Mirrors page, probeAll racing a manual probe) joins the
  /// running probe instead of firing a duplicate round of requests.
  /// Static because callers construct a fresh [MirrorSpeedTest] per
  /// call — an instance field would never see the other probe.
  static final Map<MirrorService, Future<Map<String, int?>>> _inFlight = {};

  /// Probe every enabled mirror of [service] from this device and
  /// cache the result. Returns host -> milliseconds (absent = failed).
  /// Concurrent callers for the same service share one probe.
  Future<Map<String, int?>> probe(MirrorService service) {
    final existing = _inFlight[service];
    if (existing != null) return existing;
    final future = _probe(
      service,
    ).whenComplete(() => _inFlight.remove(service));
    _inFlight[service] = future;
    return future;
  }

  Future<Map<String, int?>> _probe(MirrorService service) async {
    final urls = await InstanceManager().enabledUrls(service);
    final results = <String, int?>{};
    await Future.wait([
      for (final url in urls)
        _probeOne(url).then((ms) => results[Uri.parse(url).host] = ms),
    ]);
    unawaited(
      HiveService.settingsBox.put(_cacheKey(service), {
        'at': DateTime.now().millisecondsSinceEpoch,
        'ms': {
          for (final entry in results.entries)
            if (entry.value != null) entry.key: entry.value,
        },
      }),
    );
    return results;
  }

  /// Probe all services (the Mirrors page's speed-test button).
  Future<void> probeAll() async {
    await Future.wait([for (final s in MirrorService.values) probe(s)]);
  }

  /// Enabled mirror URLs for downloads: fresh device measurement first
  /// (fastest first), unmeasured mirrors keep SLUM order after them.
  /// Falls back to plain [InstanceManager.enabledUrls] when nothing
  /// was measured yet.
  Future<List<String>> rankedUrls(MirrorService service) async {
    final urls = await InstanceManager().enabledUrls(service);
    final ms = cachedMs(service);
    if (ms == null || ms.isEmpty) return urls;
    final measured = <String>[];
    final rest = <String>[];
    for (final url in urls) {
      (ms.containsKey(Uri.parse(url).host) ? measured : rest).add(url);
    }
    measured.sort(
      (a, b) => ms[Uri.parse(a).host]!.compareTo(ms[Uri.parse(b).host]!),
    );
    return [...measured, ...rest];
  }

  Future<int?> _probeOne(String url) async {
    final stopwatch = Stopwatch()..start();
    try {
      // Plan item 4: the probe follows redirects by hand and tells a
      // wall, a loop and an off-family hop apart — the old auto-follow
      // GET could not. A mirror that ends at a live page (or at a
      // verified redirect target) counts with its time to the
      // terminal response; anything else is unranked.
      final result = await DomainProbe.probe(
        Uri.parse(url).host,
        dio: _dio,
      );
      stopwatch.stop();
      if (result.outcome == DomainProbeOutcome.ok) {
        return stopwatch.elapsedMilliseconds;
      }
      return null;
    } catch (e) {
      AppLog.report(
        'Mirror probe failed for $url: ${e.runtimeType}',
        tag: 'mirror_speed_test',
      );
      return null;
    }
  }
}
