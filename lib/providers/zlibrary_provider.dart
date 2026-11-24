import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/hive_service.dart';
import '../services/storage_service.dart';
import 'auth_provider.dart';


/// Default mirror host.
const defaultDomain = 'bookroom.lifestyle';

/// Hosts retired from the built-in list: a persisted domain naming one
/// of these is treated as unset and falls back to [defaultDomain].
const kRetiredBuiltInDomains = {
  'zlibraryf.online',
  'zlibraryh.online',
  'zlibraryd.online',
  'zlibrary6.online',
  'zlibraryg.online',
  '777495.best',
  'freezlib.me',
  'sibaihua.pro',
  'pkuedu.online',
  '101intj.ru',
  '101w.online',
  'zlibraryj.online',
  'biblioteca.pro',
};

/// The domain the API must use from its very first request: the value
/// persisted in Hive, unless unset or retired (then [defaultDomain]).
///
/// This lives here — not in DomainNotifier — so the API is born on the
/// right line. Previously the provider returned a default-domain
/// instance and relied on DomainNotifier to fix it up, but
/// AuthNotifier's boot reverify reads this provider before anything
/// has touched domainProvider (MyApp.initState reads auth first), so
/// that first request silently went to the default host instead of the
/// user's saved line. DomainNotifier still owns later switches.
String resolveInitialDomain() {
  final saved = HiveService.settingsBox.get('domain') as String?;
  if (saved == null || kRetiredBuiltInDomains.contains(saved)) {
    return defaultDomain;
  }
  return saved;
}

/// Provider for the ZLibraryApi singleton instance.
///
/// Created on the persisted domain ([resolveInitialDomain]); Hive is
/// initialized in main() before runApp, so settingsBox is open by the
/// time any provider can be created.
final zlibraryApiProvider = Provider<ZLibraryApi>((ref) {
  final api = ZLibraryApi(domain: resolveInitialDomain());
  // 短 hash → 真 hash 解析映射进 library 盒（2026-11-21 详情提速）：
  // 解析一次，之后每次打开直接用真 hash，三连发变一发。测试用假 API
  // 走 override，不会经过这里。
  final storage = ref.read(storageServiceProvider);
  ZLibraryApiBase.resolveCacheLookup = storage.getResolvedEapiHash;
  ZLibraryApiBase.resolveCacheWrite =
      (bookId, hash, resolved) => unawaited(
        storage.putResolvedEapiHash(bookId, hash, resolved),
      );
  // Mid-session credential rejection (401 / the server's own words about
  // the session) has to reach the auth state: without it the app just shows
  // empty screens and keeps sending the refused pair until the next cold
  // boot. Wired here, at the one place the real client is built — tests
  // override this provider with fakes that carry no such field — and read
  // lazily inside the callback, so the two providers do not form a cycle
  // (AuthNotifier reads this one while building).
  api.onSessionRejected = () =>
      ref.read(authProvider.notifier).handleSessionRejected();
  return api;
});
