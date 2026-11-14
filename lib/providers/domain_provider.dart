import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/hive_service.dart';
import '../services/instance_manager.dart';
import '../services/mirror_trust.dart';
import '../services/wall_cookie_bridge.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'auth_provider.dart';
import 'cache_invalidation.dart';
import 'zlibrary_provider.dart';

/// All available mirror domains (flat list).
const kBuiltInDomains = [
  'bookroom.lifestyle',
  'bibliotheca.world',
  'bibliotheca.study',
  'bibliotheca.lifestyle',
  'luto.top',
  'bibliotheca.life',
  'anthology.lifestyle',
  'elaborate.monster',
  's0u1.top',
  '26h2.tech',
  'orangerain.space',
  'zouwu.top',
  'xn--t8j0bxa8hymnb.jp',
  '553211.xyz',
  'loves.works',
  'z-library.im',
  'ireadhuang.sbs',
  'elaborate.quest',
  'elaborate.wtf',
  '9libmirror.tech',
  'shunfei.shop',
  'elaboratethinking.online',
  'bookorg.tech',
  'booook.me',
  '95427279.xyz',
  'zkoo.site',
  'adsblaze.com',
  '817523.xyz',
  'toffeeboba.com',
  'interflow.ch',
  'free2read.cc',
  '8964520.xyz',
  'umq.me',
  '110434.xyz',
  'frank9527.site',
  'freebooks.lol',
  '226272.xyz',
  'jdbooks.xyz',
  'arcfoxxxxxx.site',
  '86110101.xyz',
  '909190.xyz',
];

/// Z-Library mirrors as open-slum.org reports them (hosts + status),
/// in the order [InstanceManager] presents them. This is the same
/// source the Mirrors settings page reads — the domain picker reuses it
/// so the two lists cannot disagree. [InstanceManager.instances] applies
/// the auto order (or the user's manual order) and returns down mirrors
/// too, which the picker needs in order to grey them out.
///
/// The catalogue is warmed at startup
/// (`InstanceManager().refreshOnStartup()`), so this usually resolves
/// from cache. While it is loading or on error, [domainListProvider]
/// falls back to [kBuiltInDomains] and [domainDownHostsProvider] is
/// empty.
final slumZlibrarySitesProvider = FutureProvider<List<SlumSite>>((ref) async {
  final views = await InstanceManager().instances(MirrorService.zlibrary);
  return [for (final view in views) view.site];
});

/// All lines the picker can offer, merged from both mirror sources:
///
///  * open-slum.org Z-Library mirrors FIRST, in SLUM order;
///  * then built-in domains not already present (deduped by host,
///    case-insensitive).
///
/// While SLUM data has never arrived (offline / cold start with no
/// cache) this is just [kBuiltInDomains] — the previous behaviour.
/// When SLUM data arrives the list updates to the merged order, and
/// every consumer that watches this provider (picker, line label,
/// network section, speed test) follows it.
final domainListProvider = Provider<List<String>>((ref) {
  final slumSites = ref.watch(slumZlibrarySitesProvider).valueOrNull;
  if (slumSites == null || slumSites.isEmpty) {
    return kBuiltInDomains;
  }
  final seen = <String>{};
  final merged = <String>[];
  for (final site in slumSites) {
    if (seen.add(site.host.toLowerCase())) merged.add(site.host);
  }
  for (final domain in kBuiltInDomains) {
    if (seen.add(domain.toLowerCase())) merged.add(domain);
  }
  return merged;
});

/// Hosts open-slum.org reports DOWN (lowercased). The domain picker
/// greys these out. Empty while SLUM data is loading or unavailable —
/// an unknown line is never treated as down.
final domainDownHostsProvider = Provider<Set<String>>((ref) {
  final slumSites = ref.watch(slumZlibrarySitesProvider).valueOrNull;
  if (slumSites == null) return const {};
  return {
    for (final site in slumSites)
      if (site.isDown) site.host.toLowerCase(),
  };
});

final domainProvider =
    NotifierProvider<DomainNotifier, String>(DomainNotifier.new);

class DomainNotifier extends Notifier<String> {
  // Getter, not `late final`: ref.invalidate re-runs build() on the SAME
  // notifier instance and a second late-final assignment throws
  // LateInitializationError (same trap documented in DownloadNotifier).
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);

  @override
  String build() {
    final initial = _initialDomain();
    if (HiveService.settingsBox.get('domain') != initial) {
      unawaited(HiveService.settingsBox.put('domain', initial));
    }
    // Ensure API is in sync with initial state (no side effects: auth init
    // handles cookie setup on first boot).
    _api.setDomain(initial);
    return initial;
  }

  // The API instance is already on the persisted domain (see
  // resolveInitialDomain): setDomain here is idempotent, and the
  // Hive write-back normalizes a retired saved value to default.
  static String _initialDomain() => resolveInitialDomain();

  /// Switch to a new line. Fire-and-forget: callers don't need to await.
  /// Internally we re-establish cookies on the new domain (reverify) and
  /// invalidate data providers so they refetch against the new line.
  ///
  /// [reverifySession] must be false for non-built-in domains: the stored
  /// session is never auto-sent to an arbitrary host. The line is flagged
  /// unavailable instead, and the user logs in again explicitly if they
  /// trust the domain.
  void setDomain(String domain, {bool reverifySession = true}) {
    if (domain == state) return;
    // O8: the WebView may hold this line's session cookies (a solver
    // installed them, or the reader did). The API session is cleared
    // below; drop the WebView pair for the OLD host too, so a later
    // anonymous solve cannot silently reuse it.
    final oldDomain = state;
    // Defence in depth (the UI normally asked already): the stored
    // session never follows the user to a community mirror they have
    // not confirmed — see MirrorTrust.
    if (reverifySession &&
        !MirrorTrust.isConfirmed(domain, builtIn: isBuiltInDomain(domain))) {
      reverifySession = false;
    }
    state = domain;
    unawaited(HiveService.settingsBox.put('domain', domain));
    // The in-memory session must not follow the user to a new host; trusted
    // (built-in) hosts get it back through reverify() below.
    _api.clearSession();
    _api.setDomain(domain);
    unawaited(deleteSessionCookies(pageUrl: 'https://$oldDomain/'));
    _refreshAfterSwitch(reverifySession: reverifySession);
  }

  /// A custom domain is valid when it is a plain hostname (or IPv4) with
  /// an optional port — no userinfo, path, query or fragment.
  static bool isValidCustomDomain(String domain) {
    final d = domain.trim();
    if (d.isEmpty || d.length > 253) return false;
    if (d.contains(RegExp(r'[\s/@?#;]'))) return false;
    final parts = d.split(':');
    if (parts.length > 2) return false;
    if (parts.length == 2) {
      final port = int.tryParse(parts[1]);
      if (port == null || port < 1 || port > 65535) return false;
    }
    final host = parts.first;
    if (host.isEmpty) return false;
    // IPv4.
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      final o = host.split('.').map((p) => int.tryParse(p) ?? 256).toList();
      if (o.any((n) => n > 255)) return false;
      // 回环 / 0.0.0.0 / 链路本地（含云元数据 169.254.169.254）不是镜像站。
      if (o[0] == 0 || o[0] == 127 || (o[0] == 169 && o[1] == 254)) {
        return false;
      }
      return true;
    }
    // DNS hostname: dot-separated labels, no leading/trailing hyphen/dot.
    if (host.startsWith('.') ||
        host.endsWith('.') ||
        host.startsWith('-') ||
        host.endsWith('-')) {
      return false;
    }
    final label = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
    return host.split('.').every((part) => label.hasMatch(part));
  }

  static bool isBuiltInDomain(String domain) {
    final host = domain.trim().split(':').first.toLowerCase();
    return host == defaultDomain || kBuiltInDomains.contains(host);
  }

  /// Strip scheme and any path / query / fragment a pasted URL may carry.
  static String normalizeCustomDomain(String domain) {
    var clean = domain.trim().replaceAll(RegExp(r'^https?://'), '');
    final cut = clean.indexOf(RegExp(r'[/?#]'));
    if (cut >= 0) clean = clean.substring(0, cut);
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean.toLowerCase();
  }

  /// Validate + switch to a custom line. Returns false when the input is
  /// not a valid domain (caller keeps the dialog open). Non-built-in
  /// domains switch WITHOUT re-sending the stored session.
  bool setCustomDomain(String domain) {
    final cleanDomain = normalizeCustomDomain(domain);
    if (!isValidCustomDomain(cleanDomain)) return false;
    setDomain(
      cleanDomain,
      reverifySession: isBuiltInDomain(cleanDomain),
    );
    return true;
  }

  Future<void> _refreshAfterSwitch({required bool reverifySession}) async {
    if (reverifySession) {
      // Cookies are domain-scoped — re-issue remix_userid/remix_userkey on the
      // new domain and re-fetch profile. This also clears the lineUnavailable
      // flag on success.
      await ref.read(authProvider.notifier).reverify();
    } else {
      // Custom domain: do NOT send the stored session here. Flag the line
      // unavailable so the user explicitly logs in again if they trust it.
      ref.read(authProvider.notifier).flagLineUnavailable();
    }
    // Bust caches for anything that depends on the line. The shared list
    // (see cache_invalidation.dart) grew out of three hand-copied blocks
    // that had already drifted apart — keep one list, not three.
    invalidateAccountScopedProviders(ref);
  }
}
