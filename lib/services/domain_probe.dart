// Domain probing (plan item 4): follow a mirror's redirects by hand
// and tell a wall, a loop and a hop to another domain apart.
//
// The speed test used to let Dio follow redirects automatically, so a
// mirror that 307s into the DiamWall challenge looked identical to one
// that 302s in a circle — both just "failed". This probe walks the
// chain itself (max 3 hops):
//
//  * a 307 carrying DiamWall markers (`Server: DiamWall`, or a
//    `__diamwall` set-cookie — see [isDiamWallResponse]) is a wall,
//    full stop — never followed, never mistaken for a loop;
//  * the same URL twice is a redirect loop;
//  * a hop to a host outside the family allow-list is verified
//    anonymously: `GET /eapi/info/domains` on the target, no
//    credentials. Only `success: 1` with a known family host in the
//    returned domains adopts the target as the current domain and
//    records it in `discovered_hosts`;
//  * cold start re-verifies every discovered host the same way and
//    drops the ones that no longer answer (see
//    [reverifyDiscoveredHosts], wired in main()).
//
// No credentials ever leave the app in this file: the probe client
// sends only the shared User-Agent (plus `source: android` on the
// `/eapi/info/domains` check — the client marker the eapi requires,
// not a credential).
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/app_log.dart';
import '../utils/host_utils.dart';
import 'hive_service.dart';
import 'http_client.dart';

/// What a domain probe concluded about one mirror.
enum DomainProbeOutcome {
  /// The chain ended at a live page (terminal status < 400).
  ok,

  /// A 307 with DiamWall markers — the wall, not a redirect.
  wall,

  /// The same URL came up twice in the chain.
  redirectLoop,

  /// The chain left the family for a host the domains check did not
  /// vouch for.
  externalRedirect,

  /// More than [DomainProbe.maxHops] redirects without terminating.
  tooManyRedirects,

  /// Transport failure, a non-https target, a redirect without a
  /// Location, or a terminal status >= 400.
  failed,
}

/// One probe's verdict: where the chain ended, and — when the chain
/// left the family for a verified target — which host was adopted.
class DomainProbeResult {
  final DomainProbeOutcome outcome;

  /// Host the chain ended at (or the hop that ended it).
  final String finalHost;

  /// Non-null when an off-allowlist target passed the domains check
  /// and was adopted (also recorded in `discovered_hosts`).
  final String? adoptedHost;

  /// Redirects followed to reach the verdict.
  final int hops;

  const DomainProbeResult({
    required this.outcome,
    required this.finalHost,
    this.adoptedHost,
    required this.hops,
  });
}

class DomainProbe {
  /// Redirects followed per probe, at most.
  static const int maxHops = 3;

  /// Per-request timeout for the root probe and the domains check.
  static const Duration requestTimeout = Duration(seconds: 8);

  /// Settings-box key for the adopted redirect targets.
  static const String discoveredHostsKey = 'discovered_hosts';

  /// Hosts a past probe adopted, in adoption order. Only hosts that
  /// passed the last cold-start re-verification are here — the
  /// re-verifier prunes the list, so a stored host is a trusted one.
  static List<String> get discoveredHosts {
    final raw = HiveService.settingsBox.get(discoveredHostsKey);
    if (raw is! List) return const [];
    final seen = <String>{};
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty)
          item.trim().toLowerCase(),
    ].where(seen.add).toList();
  }

  /// Probe [host] (a bare host, optionally with a port) and classify
  /// what its redirect chain does. [dio] is a test seam; production
  /// callers never pass it.
  static Future<DomainProbeResult> probe(String host, {Dio? dio}) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) {
      return const DomainProbeResult(
        outcome: DomainProbeOutcome.failed,
        finalHost: '',
        hops: 0,
      );
    }
    final client =
        dio ??
        createDio(
          connectTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
        );
    var current = Uri.parse('https://$trimmed/');
    final visited = <String>{_urlKey(current)};
    var hops = 0;
    for (;;) {
      final Response<ResponseBody> res;
      final cancelToken = CancelToken();
      try {
        // Stream + cancel after headers: the probe only needs the
        // status and headers, not the mirror's root page.
        res = await client
            .get<ResponseBody>(
              current.toString(),
              options: Options(
                responseType: ResponseType.stream,
                followRedirects: false,
                validateStatus: (_) => true,
              ),
              cancelToken: cancelToken,
            )
            .timeout(
              requestTimeout,
              onTimeout: () {
                cancelToken.cancel();
                throw TimeoutException('domain probe timed out');
              },
            );
      } on DioException catch (e) {
        AppLog.report(
          'Domain probe failed for $current: ${e.type}',
          tag: 'domain_probe',
        );
        return DomainProbeResult(
          outcome: DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      } on TimeoutException {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      } finally {
        cancelToken.cancel();
      }
      final code = res.statusCode ?? 0;
      if (code != 301 &&
          code != 302 &&
          code != 303 &&
          code != 307 &&
          code != 308) {
        return DomainProbeResult(
          outcome: code < 400
              ? DomainProbeOutcome.ok
              : DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      }
      // A DiamWall 307 is a wall, not a redirect: never followed, and
      // never counted as a loop even though it points at the same URL.
      if (isDiamWallResponse(status: code, headers: res.headers)) {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.wall,
          finalHost: current.host,
          hops: hops,
        );
      }
      final location = res.headers.value('location');
      if (location == null || location.isEmpty) {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      }
      final Uri next;
      try {
        next = current.resolveUri(Uri.parse(location));
      } on FormatException {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      }
      if (next.scheme != 'https') {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.failed,
          finalHost: current.host,
          hops: hops,
        );
      }
      final key = _urlKey(next);
      if (visited.contains(key)) {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.redirectLoop,
          finalHost: next.host,
          hops: hops,
        );
      }
      if (hops >= maxHops) {
        return DomainProbeResult(
          outcome: DomainProbeOutcome.tooManyRedirects,
          finalHost: next.host,
          hops: hops,
        );
      }
      if (next.host.toLowerCase() != current.host.toLowerCase()) {
        // Off the current host: a family host (or one already
        // discovered) is followed blindly. Anything else is verified
        // anonymously first — a redirect target is only adopted when
        // its own `/eapi/info/domains` vouches for it.
        if (_isAllowedHost(next)) {
          visited.add(key);
          current = next;
          hops++;
          continue;
        }
        final authority = _authority(next).toLowerCase();
        final verified = await _verifyRedirectTarget(
          authority,
          dio: client,
        );
        if (verified) {
          await _recordDiscoveredHost(authority);
          return DomainProbeResult(
            outcome: DomainProbeOutcome.ok,
            finalHost: next.host,
            adoptedHost: authority,
            hops: hops + 1,
          );
        }
        return DomainProbeResult(
          outcome: DomainProbeOutcome.externalRedirect,
          finalHost: next.host,
          hops: hops + 1,
        );
      }
      visited.add(key);
      current = next;
      hops++;
    }
  }

  /// Cold-start re-verification: every host in `discovered_hosts` is
  /// checked again against its own `/eapi/info/domains`; hosts that no
  /// longer answer (or no longer vouch for a family domain) are
  /// dropped, so a discovered host is only trusted again after it
  /// still passes. Never throws — startup must not block on it, and a
  /// failed check only costs the record (the host is re-discovered on
  /// the next probe if it comes back).
  static Future<void> reverifyDiscoveredHosts({Dio? dio}) async {
    final hosts = discoveredHosts;
    if (hosts.isEmpty) return;
    final client =
        dio ??
        createDio(
          connectTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
        );
    final kept = <String>[];
    for (final host in hosts) {
      if (await _verifyRedirectTarget(host, dio: client)) kept.add(host);
    }
    if (kept.length != hosts.length) {
      try {
        await HiveService.settingsBox.put(discoveredHostsKey, kept);
      } catch (error) {
        AppLog.report(
          'Failed to prune discovered hosts: ${error.runtimeType}',
          tag: 'domain_probe',
        );
      }
    }
  }

  /// Anonymous check of an off-allowlist redirect target: GET its
  /// `/eapi/info/domains` with no credentials. True only when the
  /// answer is `success: 1` and the returned domains contain a known
  /// family host — a look-alike domain serving its own list does not
  /// pass.
  static Future<bool> _verifyRedirectTarget(
    String authority, {
    required Dio dio,
  }) async {
    try {
      final res = await dio
          .get<String>(
            'https://$authority/eapi/info/domains',
            options: Options(
              headers: {
                'source': 'android',
                'Accept': 'application/json',
              },
              responseType: ResponseType.plain,
              followRedirects: false,
              validateStatus: (status) => status != null && status < 400,
            ),
          )
          .timeout(requestTimeout);
      final body = res.data;
      if (body == null || body.isEmpty) return false;
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return false;
      final success = decoded['success'];
      final ok = success == 1 || success == true || success == '1';
      if (!ok) return false;
      final domains = decoded['domains'];
      if (domains is! List) return false;
      return domains.whereType<String>().any(isZlibFamilyHost);
    } catch (e) {
      return false;
    }
  }

  static Future<void> _recordDiscoveredHost(String host) async {
    final hosts = discoveredHosts;
    if (hosts.contains(host)) return;
    try {
      await HiveService.settingsBox.put(discoveredHostsKey, [
        ...hosts,
        host,
      ]);
    } catch (error) {
      AppLog.report(
        'Failed to record discovered host: ${error.runtimeType}',
        tag: 'domain_probe',
      );
    }
  }

  static bool _isAllowedHost(Uri uri) {
    return isZlibFamilyHost(uri.host) ||
        discoveredHosts.contains(_authority(uri).toLowerCase());
  }

  static String _authority(Uri uri) =>
      uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

  static String _urlKey(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '${uri.scheme}://${_authority(uri).toLowerCase()}$path$query';
  }
}
