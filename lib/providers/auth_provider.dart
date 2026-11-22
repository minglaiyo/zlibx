import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/auth_storage.dart';
import '../services/challenge_html_cache.dart';
import '../services/hive_service.dart';
import '../services/random_feed_cache.dart';
import '../services/wall_cookie_bridge.dart';
import 'cache_invalidation.dart';
import 'domain_provider.dart';
import 'zlibrary_provider.dart';


class AuthState {
  final User? user;
  final bool isLoading;
  final String? error;

  /// True when auth init couldn't reach the current line (cf_blocked / network error).
  /// User is treated as logged in via cached credentials, but UI should suggest switching.
  final bool lineUnavailable;

  /// The local key store refused to answer at boot (Keystore error). The
  /// stored session says nothing either way, so it is left untouched and
  /// this is NOT "signed out": the UI should offer a retry.
  final bool storageUnavailable;

  AuthState({
    this.user,
    this.isLoading = false,
    this.error,
    this.lineUnavailable = false,
    this.storageUnavailable = false,
  });

  bool get isAuthenticated => user != null;

  /// `error: null` keeps the previous error (the copyWith idiom), so
  /// clearing needs the explicit [clearError] flag — a new login that
  /// only passed `error: null` used to leave the last failure on
  /// screen (审查3 P1).
  AuthState copyWith({
    User? user,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool? lineUnavailable,
    bool? storageUnavailable,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      lineUnavailable: lineUnavailable ?? this.lineUnavailable,
      storageUnavailable: storageUnavailable ?? this.storageUnavailable,
    );
  }
}

/// Auth state notifier
class AuthNotifier extends Notifier<AuthState> {
  late final ZLibraryApi _api;
  final AuthStorage _storage = AuthStorage();

  /// Request generation counter. Every async flow captures the epoch
  /// before its first await and re-checks it before writing state:
  /// without this, a slow-boot `_init` can "resurrect" a user who
  /// logged out while it was in flight (and a stale login result can
  /// overwrite a fresh one the same way).
  int _epoch = 0;
  bool _isCurrent(int epoch) => epoch == _epoch;

  /// Completes when the [_init] started by the current build() settles
  /// (success, auth failure, or line error — every path). Splash awaits
  /// this instead of polling `isLoading` every 500ms with a 10s cap,
  /// which misrouted logged-in users on slow lines to the login page.
  /// A fresh completer per build(): invalidate() re-runs build() on the
  /// same notifier instance, so the old (already completed) one must
  /// not be reused. [_init] captures its own completer, so a stale
  /// _init superseded by logout/login can never settle the new one.
  Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  @override
  AuthState build() {
    _api = ref.read(zlibraryApiProvider);
    _readyCompleter = Completer<void>();
    _init();
    return AuthState(isLoading: true);
  }

  Future<void> _init() async {
    // No `state = state.copyWith(isLoading: true)` here: build() already
    // returns AuthState(isLoading: true) as the initial state, and reading
    // state inside build() would throw (not yet initialized).
    final epoch = _epoch;
    final completer = _readyCompleter;
    try {
      final Map<String, String?> credentials;
      try {
        credentials = await _storage.getCredentials();
      } on CredentialStorageUnavailable catch (e) {
        if (!_isCurrent(epoch)) return;
        // The local key store would not answer — after AuthStorage retried.
        // That says nothing about the stored pair, so nothing is cleared and
        // the caller can retry; reporting it as "signed out" sent users to
        // the login page with a perfectly good session on disk.
        logIgnored('auth_provider', e);
        state = AuthState(storageUnavailable: true, error: e.toString());
        return;
      }
      if (!_isCurrent(epoch)) return;
      final userId = credentials['userId'];
      final userKey = credentials['userKey'];

      if (userId == null || userKey == null) {
        state = AuthState();
        return;
      }

      // Build a fallback User from cached fields so we can stay logged in
      // even when the current line is unreachable.
      User cachedUser() => User(
        id: userId,
        email: credentials['email'] ?? '',
        name: credentials['name'] ?? 'User',
        remixUserkey: userKey,
      );

      // A custom (non built-in) line persisted from a previous run must
      // never receive the stored session automatically at boot.
      final savedDomain =
          (HiveService.settingsBox.get('domain') as String?) ?? defaultDomain;
      if (!DomainNotifier.isBuiltInDomain(savedDomain)) {
        state = AuthState(user: cachedUser(), lineUnavailable: true);
        return;
      }

      try {
        // Use loginWithToken — it sets remix_userid/remix_userkey cookies on
        // Dio and hits /eapi/user/profile directly, so it works even on a
        // fresh boot when the api's internal _loggedIn flag is still false.
        final response = await _api.loginWithToken(userId, userKey);
        if (!_isCurrent(epoch)) return;

        if (response.success && response.data != null) {
          state = AuthState(user: response.data);
        } else if (response.authRejected) {
          // The line read the pair itself and said no (401, or the server's
          // own message about the session) — drop that account's creds,
          // and make sure the plugin instance no longer holds the rejected
          // pair. This is the ONLY branch allowed to delete anything at
          // boot. Only the rejected account goes: the other saved
          // accounts keep their sessions.
          _api.clearSession();
          await _storage.clearAccount(userId);
          unawaited(_dropWebViewSession());
          if (!_isCurrent(epoch)) return;
          state = AuthState();
        } else {
          // No verdict about the credentials: a wall page, a 5xx / 429, an
          // empty or non-JSON body, a success:0 that only says "slow down",
          // a payload without a user object, a cancelled call. Keep the
          // pair and suggest another line — clearing it here is what the
          // substring table used to do to every one of those, and it is the
          // reported 重进 App 掉登录: `clearCredentials` also deletes the
          // saved-accounts list, so a bad network day cost the password.
          state = AuthState(user: cachedUser(), lineUnavailable: true);
        }
      } catch (e) {
        if (!_isCurrent(epoch)) return;
        // Network exception — assume line issue, keep using cached creds.
        state = AuthState(user: cachedUser(), lineUnavailable: true);
      }
    } catch (e) {
      if (!_isCurrent(epoch)) return;
      state = AuthState(error: e.toString());
    } finally {
      // Every path settles `ready`, including early returns above
      // (finally runs on return too) and the epoch guard: a stale _init
      // completes only the completer it captured, never the current one.
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// Heuristic: the LINE failed, the credentials said nothing. Connection
  /// errors and the wall pages are line problems — we don't wipe credentials
  /// over a network blip, and we don't blame the session either. This is now
  /// only the hint that marks the line unavailable in [reverify]; the
  /// destructive verdict comes from `ApiResponse.authRejected` alone.
  bool _isTransientError(String? error) {
    if (error == null) return false;
    final e = error.toLowerCase();
    return e.contains('cf_blocked') ||
        e.contains('line_error') ||
        e.contains('timeout') ||
        e.contains('socket') ||
        e.contains('connection') ||
        e.contains('network') ||
        e.contains('handshake') ||
        e.contains('unreachable') ||
        e.contains('failed host lookup') ||
        e.contains('request failed');
  }

  /// The WebView cookie jar is the second holder of the same pair: a solve
  /// flow or the online reader installs `remix_userid` / `remix_userkey`
  /// there, and that store is plain on-disk SQLite. A logout that only
  /// cleared the API and the Keystore left the refused pair sitting in the
  /// jar for the current line, so every path that decides a pair is dead
  /// drops it here too (best effort — [deleteSessionCookies] never throws).
  Future<void> _dropWebViewSession() =>
      deleteSessionCookies(pageUrl: 'https://${_api.domain}/');

  Future<bool> login(String email, String password) async {
    ChallengeHtmlCache.clear();
    // A new login invalidates any in-flight init/previous flow: from here
    // on only this flow may write auth state.
    final epoch = ++_epoch;
    // Drop any session still held from a previous account BEFORE trying:
    // otherwise the plugin's rpc-login fallback could mistake the old
    // in-memory pair for a successful login and "log in" the wrong user.
    _api.clearSession();
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await _api.login(email, password);
      if (!_isCurrent(epoch)) return false;

      if (response.success && response.data != null) {
        final user = response.data!;

        await _storage.saveCredentials(
          userId: user.id,
          userKey: user.remixUserkey,
          email: user.email,
          name: user.name,
        );
        if (!_isCurrent(epoch)) return false;

        state = AuthState(user: user);
        return true;
      } else {
        state = AuthState(error: response.error ?? 'Login failed');
        return false;
      }
    } catch (e) {
      if (!_isCurrent(epoch)) return false;
      state = AuthState(error: e.toString());
      return false;
    }
  }

  Future<bool> loginWithToken(String userId, String userKey) async {
    ChallengeHtmlCache.clear();
    final epoch = ++_epoch;
    _api.clearSession();
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await _api.loginWithToken(userId, userKey);
      if (!_isCurrent(epoch)) return false;

      if (response.success && response.data != null) {
        state = AuthState(user: response.data);
        return true;
      } else {
        state = AuthState(error: response.error ?? 'Token login failed');
        return false;
      }
    } catch (e) {
      if (!_isCurrent(epoch)) return false;
      state = AuthState(error: e.toString());
      return false;
    }
  }

  /// Adopt a session the user created on the site INSIDE the reader
  /// WebView (the login wall) — reported by ReaderScreen via
  /// [ReaderArgs.onSessionChanged] once the WebView cookie store holds
  /// a `remix_userid` / `remix_userkey` pair different from the one the
  /// app installed.
  ///
  /// Without this, a WebView-side login stays invisible to the app: the
  /// server rotates the userkey, so the stored pair goes stale, the next
  /// 预览 re-installs the stale pair and the site bounces the user back
  /// to its login wall, and a later boot's loginWithToken treats the
  /// stale pair as a real auth failure and WIPES the credentials. No
  /// network call here — the site itself just proved the pair — only
  /// adoption, persistence and state.
  Future<void> adoptWebViewSession(String userId, String userKey) async {
    // Cancel any in-flight auth flow (slow _init / refreshProfile built
    // around the old pair must not overwrite the adopted session).
    final epoch = ++_epoch;
    final previous = state.user;
    final sameAccount = previous?.id == userId;

    _api.adoptSession(userId, userKey);
    await _storage.saveCredentials(
      userId: userId,
      userKey: userKey,
      // Same account: keep the stored email/name. A different account
      // logged in inside the WebView: its identity is unknown until the
      // profile refresh below, so clear the stale fields instead of
      // leaving the previous account's name on the new session.
      email: sameAccount ? previous?.email : '',
      name: sameAccount ? previous?.name : '',
    );
    if (!_isCurrent(epoch)) return;

    state = AuthState(
      user: User(
        id: userId,
        email: sameAccount ? (previous?.email ?? '') : '',
        name: sameAccount ? (previous?.name ?? 'User') : 'User',
        remixUserkey: userKey,
        downloadsLeft: sameAccount ? previous?.downloadsLeft : null,
      ),
    );
    if (!sameAccount) {
      invalidateAccountScopedProviders(ref);
    }
    // Best effort: fill email/name/downloadsLeft from the live profile.
    // refreshProfile keeps state untouched on error, so a challenge wall
    // between us and /eapi/user/profile costs nothing.
    await refreshProfile();
  }

  Future<void> logout() async {
    // Kill every in-flight auth flow first: a slow _init/profile fetch
    // must not resurrect the user right after logout.
    _epoch++;
    ChallengeHtmlCache.clear();
    // The plugin holds the session pair in memory and appends it to every
    // request's Cookie header. Without this the app is "logged out" in the
    // UI but keeps sending the logged-out account's remix_* cookies on
    // every search/detail call until the process restarts.
    _api.clearSession();
    // Only the account being logged out leaves the device: the other
    // saved accounts keep their session keys.
    await _storage.clearAccount(state.user?.id);
    // Session cookies installed for the online reader live in the WebView
    // cookie store; clear them too so logout really logs out everywhere.
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (error) {
      logIgnored('auth_provider', error);
      // WebView never initialized — nothing to clear.
    }
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (error) {
      logIgnored('auth_provider', error);
    }
    try {
      await InAppWebViewController.clearAllCache();
    } catch (error) {
      logIgnored('auth_provider', error);
    }
    state = AuthState();
    // Same account-scoped caches as an account switch: a later login
    // as a different account must not see the old account's data.
    invalidateAccountScopedProviders(ref);
    // 登出清掉按账号分键的随机批缓存（审查 v2 P3 隐私面）：旧账号看
    // 过/被推荐过什么不该留在盘上。
    unawaited(RandomFeedCache.clearAll());
  }

  /// Mark the current line unavailable without sending any credentials:
  /// used after switching to a custom domain, where the stored session
  /// must not be auto-sent until the user explicitly logs in again.
  void flagLineUnavailable() {
    state = state.copyWith(lineUnavailable: true);
  }

  Future<void> refreshProfile() async {
    if (!state.isAuthenticated) return;
    final epoch = _epoch;

    try {
      final response = await _api.getProfile();
      if (!_isCurrent(epoch)) return;
      if (response.success && response.data != null) {
        state = AuthState(user: response.data);
      }
    } catch (e) {
      // Keep existing state on error — but leave a trail (审查 v2 P2-2).
      logIgnored('auth_profile_refresh', e);
    }
  }

  /// The plugin just watched the current line refuse the pair it carries
  /// (see `ZLibraryApiBase.onSessionRejected`): an HTTP 401, or a `success: 0`
  /// whose message is about the session. Nothing in the app used to react —
  /// the pair stayed in memory and on disk, so every later request failed the
  /// same way while the UI still showed a signed-in avatar.
  ///
  /// Re-verify once against the real profile endpoint instead of trusting one
  /// 401 from an endpoint in front of the account API:
  ///
  ///  * the profile loads again → the refusal came from something upstream
  ///    (a proxy, a half-cleared cookie jar, an endpoint that 401s for other
  ///    reasons) and the session stays exactly where it was;
  ///  * the profile refuses the pair too → [reverify] logs out with the
  ///    server's reason, which is the honest end of a session the server
  ///    killed (key rotation, password change, "log out everywhere");
  ///  * the line gives no verdict → [reverify] keeps the user and marks the
  ///    line unavailable.
  ///
  /// Guarded so a page whose dozen requests all 401 starts exactly one check,
  /// and so the check's own rejection cannot recurse into itself.
  bool _sessionRecheckRunning = false;

  Future<void> handleSessionRejected() async {
    if (_sessionRecheckRunning) return;
    // Nothing to heal while the app does not believe it is signed in: the
    // user is already on the login page, and wiping here would also race a
    // login flow that is mid-flight.
    if (!state.isAuthenticated) return;
    _sessionRecheckRunning = true;
    try {
      await reverify();
    } finally {
      _sessionRecheckRunning = false;
    }
  }

  /// Re-verify the current line/credentials. Used after the user switches
  /// network line, and after the plugin reports a refusal, to refresh the
  /// lineUnavailable flag and pick up the real profile.
  Future<void> reverify() async {
    final epoch = _epoch;
    final Map<String, String?> credentials;
    try {
      credentials = await _storage.getCredentials();
    } on CredentialStorageUnavailable catch (error) {
      if (!_isCurrent(epoch)) return;
      logIgnored('auth_provider', error);
      // Same rule as boot: a key store that will not answer is not a logout,
      // and there is nothing to re-send anyway.
      state = state.copyWith(storageUnavailable: true);
      return;
    }
    if (!_isCurrent(epoch)) return;
    final userId = credentials['userId'];
    final userKey = credentials['userKey'];
    if (userId == null || userKey == null) return;

    try {
      final response = await _api.loginWithToken(userId, userKey);
      if (!_isCurrent(epoch)) return;
      if (response.success && response.data != null) {
        state = AuthState(user: response.data);
      } else if (response.authRejected) {
        // The line read the pair and said no — and this call asked it twice
        // (the refusal is what started the re-check). Clearing here is what a
        // dead session actually needs: keeping it would fail every request
        // while the UI still claimed a signed-in user. Only the dead
        // account goes; the other saved accounts are untouched.
        _api.clearSession();
        await _storage.clearAccount(userId);
        await _dropWebViewSession();
        if (!_isCurrent(epoch)) return;
        invalidateAccountScopedProviders(ref);
        state = AuthState(error: response.error ?? 'session rejected');
      } else if (_isTransientError(response.error)) {
        // Still unreachable — keep current user but mark line unavailable.
        state = state.copyWith(lineUnavailable: true);
      }
      // Other errors: leave existing state alone; user can logout manually.
    } on Object catch (error) {
      if (!_isCurrent(epoch)) return;
      logIgnored('auth_provider', error);
      state = state.copyWith(lineUnavailable: true);
    }
  }

  Future<List<Map<dynamic, dynamic>>> getSavedAccounts() async {
    return await _storage.getStoredAccounts();
  }

  Future<bool> switchAccount(Map<String, dynamic> account) async {
    final userId = account['userId']?.toString();
    final userKey = account['userKey']?.toString();
    final email = account['email']?.toString();

    if (userId != null && userKey != null) {
      final success = await loginWithToken(userId, userKey);
      if (success) {
        await _storage.saveCredentials(
          userId: userId,
          userKey: userKey,
          email: state.user?.email ?? email,
          name: state.user?.name ?? account['name']?.toString(),
        );
        // Bust caches for anything that depends on the account, like
        // the line change does (see domain_provider): otherwise the
        // library keeps showing the previous account's books until a
        // manual refresh.
        invalidateAccountScopedProviders(ref);
        // O8: the WebView may still hold the previous account's
        // session cookies for this mirror. Solver flows install fresh
        // ones, but a sign-in page solved without credentials would
        // silently reuse the old account's — drop them now that the
        // new session is in place.
        await deleteSessionCookies(pageUrl: 'https://${_api.domain}/');
      }
      return success;
    }
    // No session keys and no stored password (passwords are never persisted):
    // this account cannot be switched to without logging in again.
    return false;
  }

  Future<void> removeAccount(String userId) async {
    await _storage.removeAccount(userId);
  }
}

/// Auth state provider
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
