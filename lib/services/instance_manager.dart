// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/instance_manager.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
// Dart imports:
import 'dart:convert';

// Package imports:
import 'package:meta/meta.dart';

// Project imports:
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/preference_store.dart';
import 'package:zlibx/services/slum_catalogue.dart';
import 'package:zlibx/services/hive_preference_store.dart';
import 'package:zlibx/utils/diagnostics.dart';

// MirrorService and the SLUM model live in the catalogue; re-exported so
// callers keep importing only this file.
export 'package:zlibx/services/slum_catalogue.dart'
    show MirrorService, SlumStatus, SlumSite, Protection, ProtectionRank;

/// One mirror as the settings screen shows it: the SLUM reading plus the
/// user's own enable/disable choice.
@immutable
class InstanceView {
  final SlumSite site;

  /// The user's switch for this host, independent of SLUM's status: a
  /// disabled mirror stays disabled even when it comes back up. A mirror
  /// SLUM reports DOWN is masked out separately ([isDown], and
  /// [InstanceManager.enabledUrls] never returns it), so it is greyed in
  /// the UI while still carrying the user's own on/off choice.
  final bool enabled;

  const InstanceView({required this.site, required this.enabled});

  bool get isDown => site.isDown;
  String get host => site.host;
  String get url => site.url;
}

/// Outcome of a mirror-list refresh: what changed, and whether the app
/// has a mirror list at all (false when open-slum.org was unreachable
/// and nothing was cached - "up to date" would then be a lie).
class MirrorRefreshResult {
  final List<String> changes;
  final bool hasMirrorList;

  const MirrorRefreshResult({
    required this.changes,
    required this.hasMirrorList,
  });
}

/// Decides **which mirrors the app may talk to, and in what order**.
///
/// There are no default mirror URLs here: the list comes from
/// [SlumCatalogue] (open-slum.org), and this class only layers the
/// user's choices on top:
///
///  * **Auto mode** (the default): mirrors are ordered by how hard their
///    protection is to pass headlessly - unprotected first, then
///    DiamWall, then the browser-only DDoS-Guard/Cloudflare gates - and
///    within a tier by SLUM's latency reading. A mirror SLUM reports
///    DOWN is never returned by [enabledUrls].
///  * **Manual mode**: the user drags their own order; anything they
///    never ordered keeps its auto position after the pinned ones.
///
/// Disabling a mirror (in either mode) removes it from [enabledUrls]
/// permanently until the user turns it back on. Down mirrors are listed
/// in the UI but can never be enabled.
class InstanceManager {
  static final InstanceManager _instance = InstanceManager._internal();
  factory InstanceManager() => _instance;

  InstanceManager._internal()
    : _catalogue = SlumCatalogue(store: HivePreferenceStore()),
      _store = HivePreferenceStore();

  /// Tests build their own with an injected catalogue/store.
  InstanceManager.forTest({SlumCatalogue? catalogue, PreferenceStore? store})
    : _catalogue = catalogue ?? SlumCatalogue(),
      _store = store;

  final SlumCatalogue _catalogue;
  final PreferenceStore? _store;
  final AppLogger _logger = AppLogger();

  static const String _autoModeKey = 'instance_auto_mode';
  static const String _orderKey = 'instance_manual_order';
  static const String _disabledKey = 'instance_disabled_hosts';

  /// Auto mode is the default: the user asked for the app to pick the
  /// easiest mirror itself and only reorder by hand if they opt in.
  Future<bool> isAutoMode() async {
    try {
      final value = await _store?.read(_autoModeKey);
      return value == null ? true : value == true || value == 1;
    } catch (error) {
      logIgnored('instance_manager', error);
      return true;
    }
  }

  Future<void> setAutoMode(bool auto) async {
    await _store?.write(_autoModeKey, auto);
    _logger.info(
      'Instance mode changed',
      tag: 'InstanceManager',
      metadata: {'mode': auto ? 'auto' : 'manual'},
    );
  }

  // ------------------------------------------------------------------
  // User preferences (per service, keyed by host).
  // ------------------------------------------------------------------

  /// In-memory copy of the host maps (disabled hosts, manual order), so
  /// a search does not pay a Hive read + jsonDecode on every request.
  /// [_readHostMap] always hands out a copy, so callers can never mutate
  /// the cached data; [_writeHostMap] drops the entry, so the next read
  /// re-reads from the store.
  final Map<String, Map<String, List<String>>> _hostMapCache = {};

  Future<Map<String, List<String>>> _readHostMap(String key) async {
    final cached = _hostMapCache[key];
    if (cached != null) return _copyHostMap(cached);
    try {
      final raw = await _store?.read(key);
      if (raw is! String || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final map = <String, List<String>>{
        for (final entry in decoded.entries)
          if (entry.value is List)
            entry.key: [for (final v in entry.value as List) v.toString()],
      };
      _hostMapCache[key] = map;
      return _copyHostMap(map);
    } catch (error) {
      logIgnored('instance_manager', error);
      return {};
    }
  }

  static Map<String, List<String>> _copyHostMap(Map<String, List<String>> map) {
    return {
      for (final entry in map.entries) entry.key: [...entry.value],
    };
  }

  Future<void> _writeHostMap(String key, Map<String, List<String>> map) async {
    await _store?.write(key, jsonEncode(map));
    // The stored value now matches [map]: refresh the in-memory copy
    // (a defensive deep copy, same as _readHostMap returns) instead of
    // dropping it — dropping it made every toggle re-read Hive and
    // re-run jsonDecode on the next read.
    _hostMapCache[key] = _copyHostMap(map);
  }

  /// Hosts the user switched off for [service].
  Future<Set<String>> disabledHosts(MirrorService service) async {
    final map = await _readHostMap(_disabledKey);
    return (map[service.name] ?? const []).toSet();
  }

  Future<void> setEnabled(
    MirrorService service,
    String host,
    bool enabled,
  ) async {
    final map = await _readHostMap(_disabledKey);
    final list = map[service.name] ?? <String>[];
    if (enabled) {
      list.remove(host);
    } else if (!list.contains(host)) {
      list.add(host);
    }
    map[service.name] = list;
    await _writeHostMap(_disabledKey, map);
    _logger.info(
      enabled ? 'Mirror enabled' : 'Mirror disabled',
      tag: 'InstanceManager',
      metadata: {'host': host},
    );
  }

  /// The user's manual order for [service] (host list, first = preferred).
  Future<List<String>> manualOrder(MirrorService service) async {
    final map = await _readHostMap(_orderKey);
    return map[service.name] ?? const [];
  }

  /// Pins the full manual order for a service; hosts not in [hosts] fall
  /// back to their auto position.
  Future<void> setManualOrder(MirrorService service, List<String> hosts) async {
    final map = await _readHostMap(_orderKey);
    map[service.name] = hosts;
    await _writeHostMap(_orderKey, map);
  }

  /// Moves [host] one slot up or down in the manual order, materialising
  /// the current order first so a drag works the way the user sees it.
  Future<void> move(MirrorService service, String host, int delta) async {
    final current = await instances(service);
    final hosts = current.map((v) => v.host).toList();
    final index = hosts.indexOf(host);
    if (index == -1) return;
    final target = (index + delta).clamp(0, hosts.length - 1);
    if (target == index) return;
    hosts.removeAt(index);
    hosts.insert(target, host);
    await setManualOrder(service, hosts);
  }

  // ------------------------------------------------------------------
  // The mirror list itself.
  // ------------------------------------------------------------------

  /// Every mirror of [service] in display order, including down and
  /// disabled ones, each with the user's enabled flag.
  ///
  /// Auto mode: SLUM order (see [SlumCatalogue.sortAuto]).
  /// Manual mode: the user's pinned order first, then the auto tail.
  Future<List<InstanceView>> instances(
    MirrorService service, {
    bool force = false,
  }) async {
    final sites = await _catalogue.sites(service, force: force);
    final ordered = SlumCatalogue.sortAuto(sites);

    // The auto-mode flag and the disabled list are needed in both modes
    // and do not depend on each other, so they are read together; the
    // manual order is only read when auto mode is off.
    final results = await Future.wait([isAutoMode(), disabledHosts(service)]);
    final auto = results[0] as bool;
    final disabled = results[1] as Set<String>;
    final List<SlumSite> finalOrder;
    if (auto) {
      finalOrder = ordered;
    } else {
      final pinned = await manualOrder(service);
      final byHost = {for (final site in ordered) site.host: site};
      final result = <SlumSite>[];
      for (final host in pinned) {
        final site = byHost.remove(host);
        if (site != null) result.add(site);
      }
      result.addAll(byHost.values);
      finalOrder = result;
    }

    return [
      for (final site in finalOrder)
        InstanceView(
          site: site,
          // The user's own switch; down mirrors are masked by the UI and
          // by enabledUrls, not by this flag.
          enabled: !disabled.contains(site.host),
        ),
    ];
  }

  /// The enabled, attemptable mirrors of [service] in request order.
  /// Shared by [enabledUrls] and [hasUnprotectedMirror] so both decide
  /// from the same list: mirrors SLUM reports DOWN and mirrors the user
  /// switched off are out, and [headlessOnly] additionally drops any
  /// mirror a plain Dio client cannot pass.
  Future<List<InstanceView>> _enabledViews(
    MirrorService service, {
    bool force = false,
    bool headlessOnly = false,
  }) async {
    final views = await instances(service, force: force);
    return [
      for (final view in views)
        if (view.enabled && view.site.isAttemptable)
          if (!headlessOnly || view.site.protection.solvableHeadless) view,
    ];
  }

  /// The mirror URLs a provider may actually request, best first.
  ///
  /// Excludes:
  ///  * mirrors SLUM reports DOWN - never tried, per the app's contract;
  ///  * mirrors the user switched off;
  ///  * mirrors whose protection is browser-only while the caller asked
  ///    for headless-only ([headlessOnly]).
  Future<List<String>> enabledUrls(
    MirrorService service, {
    bool force = false,
    bool headlessOnly = false,
  }) async {
    final views = await _enabledViews(
      service,
      force: force,
      headlessOnly: headlessOnly,
    );
    return [for (final view in views) view.site.url];
  }

  /// True when at least one mirror [enabledUrls] would return for
  /// [service] has no bot challenge ([Protection.none]) — i.e. a plain
  /// Dio request has a chance. False when the list is empty or every
  /// enabled mirror sits behind a challenge (DiamWall, DDoS-Guard,
  /// Cloudflare or unknown): Dio would only time out on those, so
  /// callers can skip straight to the WebView solve.
  Future<bool> hasUnprotectedMirror(
    MirrorService service, {
    bool force = false,
  }) async {
    final views = await _enabledViews(service, force: force);
    return views.any((view) => view.site.protection == Protection.none);
  }

  /// Refreshes from open-slum.org and reports what changed, for the
  /// upgrade screen. Returns human-readable lines like `+ z-lib.gd`.
  Future<MirrorRefreshResult> refresh() async {
    final before = await _catalogue.fetchAll();
    final after = await _catalogue.fetchAll(force: true);

    final changes = <String>[];
    for (final service in MirrorService.values) {
      final oldHosts = (before[service] ?? const []).map((s) => s.host).toSet();
      final newHosts = (after[service] ?? const []).map((s) => s.host).toSet();
      for (final host in newHosts.difference(oldHosts)) {
        changes.add('+ $host (${service.name})');
      }
      for (final host in oldHosts.difference(newHosts)) {
        changes.add('- $host (${service.name})');
      }
    }
    _logger.info(
      'Mirror list refreshed from open-slum.org',
      tag: 'InstanceManager',
      metadata: {'changes': changes.length},
    );
    return MirrorRefreshResult(
      changes: changes,
      hasMirrorList: _catalogue.lastFetchSucceeded,
    );
  }

  /// Warms the catalogue at startup so the first search does not wait on
  /// open-slum.org. Never throws.
  Future<void> refreshOnStartup() async {
    try {
      await _catalogue.restore();
      await _catalogue.fetchAll();
    } catch (e) {
      _logger.warning(
        'Startup mirror refresh failed',
        tag: 'InstanceManager',
        error: e,
      );
    }
  }
}
