// Auth domain of [ZLibraryApi]: login, registration codes,
// profile, and the in-memory session. Split out of
// `zlibrary_api.dart` (item 7, step 1) as a mixin in the
// same library, so it can use the base class's private HTTP
// helpers (`_get`, `_postForm`, ...) and session fields
// (`_userId`, `_userKey`, `_wallCookies`) directly. The
// mixin is `on ZLibraryApiBase`, the abstract base that
// holds those members — it cannot name the class itself
// as its supertype constraint, because a mixin applied to
// a class cannot have that class as its `on` type (the
// application would make the class a supertype of itself). A mixin in
// a separate library could not see those privates without
// changing the public interface (which the six test fakes
// implement), and thin delegation would need the helpers
// passed in as callbacks — a rewrite, not a move.
// `ZLibraryApi` itself stays whole in `zlibrary_api.dart`
// and extends the base: `class ZLibraryApi extends
// ZLibraryApiBase with ZLibraryAuth`.
part of 'zlibrary_api.dart';

/// Auth / session methods for [ZLibraryApi].
mixin ZLibraryAuth on ZLibraryApiBase {
  /// Drop the in-memory session so the Cookie header is no longer sent.
  /// Call before switching to a host that is not trusted; trusted hosts
  /// re-issue the session explicitly via [loginWithToken].
  void clearSession() {
    _userId = null;
    _userKey = null;
    _wallCookies.clear();
  }

  /// Adopt a session pair learned outside this API layer — e.g. the user
  /// signed in on the site inside the reader WebView, and the app copied
  /// the fresh `remix_userid` / `remix_userkey` back from the WebView's
  /// cookie store (see `ReaderScreen`). Unlike [loginWithToken] this
  /// performs no network call: the site itself just proved the pair
  /// against the live session, so validating it again would only add a
  /// round trip (and could even fail behind a challenge wall). Wall
  /// cookies are kept — they describe the mirror, not the account.
  void adoptSession(String userId, String userKey) {
    _userId = userId;
    _userKey = userKey;
  }

  /// Remember wall-clearance cookies the WebView earned by passing a
  /// browser check (see `wall_cookie_bridge.dart` in the app). They
  /// are appended to the `Cookie` header on every request to our own
  /// mirror, so the next HTML load skips the solver. Session cookies
  /// are ignored here — the plugin already sends those from its own
  /// session. Empty values are dropped. Merging by name keeps a newer
  /// solve's value while preserving cookies from an earlier one.
  void setWallCookies(Map<String, String> cookies) {
    for (final entry in cookies.entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isEmpty ||
          value.isEmpty ||
          name == 'remix_userid' ||
          name == 'remix_userkey') {
        continue;
      }
      _wallCookies[name] = value;
    }
  }

  void _learnSession(Map<String, dynamic> json, List<String> setCookie) {
    // From Set-Cookie headers first (the server's own session values).
    for (final cookie in setCookie) {
      for (final part in cookie.split(';')) {
        final trimmed = part.trim();
        final eq = trimmed.indexOf('=');
        // Values may legitimately contain '=' (base64 padding): split on
        // the FIRST '=' only, not every one. An empty value is not a
        // session — adopting it would send `remix_userkey=` (empty) on
        // every later request.
        if (eq <= 0) continue;
        final name = trimmed.substring(0, eq);
        final value = trimmed.substring(eq + 1);
        if (value.isEmpty) continue;
        if (name == 'remix_userid') _userId = value;
        if (name == 'remix_userkey') _userKey = value;
      }
    }
    // Then from the user object, which carries the same pair.
    final userJson = ZLibraryApiBase._userJson(json);
    if (userJson != null) {
      final id = userJson['id']?.toString();
      final key = (userJson['remixUserkey'] ?? userJson['remix_userkey'])
          ?.toString();
      if (id != null && id.isNotEmpty) _userId = id;
      if (key != null && key.isNotEmpty) _userKey = key;
    }
  }

  // ── Auth ───────────────────────────────────────────────────────────

  /// Website-login fields, sent alongside email/password on the eapi
  /// login call. The eapi clients that work against z-lib's own domains
  /// send only email+password, but the community mirrors in this app's
  /// line list answered that shape with HTTP 400 on every line while the
  /// original app logs in fine — so the mirrors' login handler appears
  /// to want the website login's field set. EAPI handlers ignore unknown
  /// fields, so including them costs nothing where email+password alone
  /// already works.
  static const Map<String, String> _loginExtraFields = {
    'isModal': 'true',
    'site_mode': 'books',
    'action': 'login',
    'isSingleLogin': '1',
    'redirectUrl': '',
    'gg_json_mode': '1',
  };

  Future<ApiResponse<User>> login(String email, String password) async {
    final fields = <String, dynamic>{
      'email': email,
      'password': password,
      ..._loginExtraFields,
    };
    final raw = await _postForm('/eapi/user/login', fields);
    if (raw.json != null && ZLibraryApiBase._isSuccess(raw.json!)) {
      return _finishLogin(raw.json!, raw.cookies);
    }
    // EAPI login did not succeed. Fall back to the website login RPC on
    // the same mirror: the original app logs in on these lines, and the
    // website login is the other shape a mirror's login handler may
    // expect. If rpc.php is not served here either, the original eapi
    // error is reported, not the fallback's.
    //
    // A structured eapi rejection (an explicit error/message field, e.g.
    // "wrong email or password") is a definitive business error: the same
    // credentials will be rejected by /rpc.php too, and resubmitting them
    // only doubles the mirror's lock-out risk. Fall back only when the
    // eapi answer looks like a protocol mismatch (no usable error text).
    // (The null check must be the direct `if` condition: Dart only
    // promotes locals on a direct test, not via a boolean variable.)
    final eapiErrorText =
        (raw.json?['error'] ?? raw.json?['message'])?.toString().trim();
    if (eapiErrorText != null && eapiErrorText.isNotEmpty) {
      return ApiResponse.fail(eapiErrorText, statusCode: raw.status);
    }
    final rpc = await _postForm('/rpc.php', fields);
    if (rpc.json != null) {
      final rpcJson = rpc.json!;
      final validationError = rpcJson['validationError']?.toString().trim();
      if (validationError != null && validationError.isNotEmpty) {
        return ApiResponse.fail(validationError, statusCode: rpc.status);
      }
      // Compare against the session that was installed BEFORE this call:
      // if _learnSession learned nothing, a pair left over from a previous
      // account would still make `_userId != null && _userKey != null`
      // true, and the profile fetch would "successfully" log the previous
      // account in with this account's password.
      final prevUserId = _userId;
      final prevUserKey = _userKey;
      _learnSession(rpcJson, rpc.cookies);
      final learnedNewSession = (_userId != null && _userId != prevUserId) ||
          (_userKey != null && _userKey != prevUserKey);
      if (learnedNewSession && _userId != null && _userKey != null) {
        final profile = await getProfile();
        if (profile.success && profile.data != null) return profile;
        return ApiResponse.fail(
          profile.error ?? 'login succeeded but no user data',
          statusCode: profile.statusCode,
        );
      }
      if (ZLibraryApiBase._userJson(rpcJson) != null) {
        return _finishLogin(rpcJson, rpc.cookies);
      }
    }
    if (raw.json != null) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'login failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.fail(raw.error ?? 'login failed',
        statusCode: raw.status);
  }

  /// The user object in login/profile payloads does not always carry the
  /// session key — it usually arrives via Set-Cookie instead. But the app
  /// persists `user.remixUserkey` as its stored credential and hands it to
  /// the reader WebView, so a User with an empty key silently breaks both.
  /// Fill it from the session this layer already learned, when available.
  User _withSessionKey(User user) {
    if (user.remixUserkey.isNotEmpty) return user;
    final key = _userKey;
    if (key == null || key.isEmpty) return user;
    return User(
      id: user.id,
      email: user.email,
      name: user.name,
      remixUserkey: key,
      downloadsLeft: user.downloadsLeft,
    );
  }

  /// Shared tail of a successful login: learn the session pair from
  /// Set-Cookie headers and/or the user object; if the payload has no
  /// user object, a profile fetch fills it in.
  Future<ApiResponse<User>> _finishLogin(
    Map<String, dynamic> json,
    List<String> cookies,
  ) async {
    _learnSession(json, cookies);
    final userJson = ZLibraryApiBase._userJson(json);
    if (userJson == null) {
      final profile = await getProfile();
      if (profile.success && profile.data != null) return profile;
      return ApiResponse.fail(
        profile.error ?? 'login succeeded but no user data',
        statusCode: profile.statusCode,
      );
    }
    final user = User.fromJson(userJson);
    _userId ??= user.id.isNotEmpty ? user.id : null;
    _userKey ??= user.remixUserkey.isNotEmpty ? user.remixUserkey : null;
    return ApiResponse.ok(_withSessionKey(user));
  }

  /// Install a stored `remix_userid` / `remix_userkey` pair and validate
  /// it against `/eapi/user/profile`. This is what the app calls on boot
  /// and after a domain switch.
  Future<ApiResponse<User>> loginWithToken(
    String userId,
    String userKey,
  ) async {
    _userId = userId;
    _userKey = userKey;
    final profile = await getProfile();
    if (!profile.success) {
      // Do not leave an unvalidated (possibly stale or rejected) pair
      // installed: every later request would keep sending its cookies,
      // and a subsequent login()'s rpc fallback would mistake the stale
      // pair for a successful login of the wrong account.
      _userId = null;
      _userKey = null;
    }
    return profile;
  }

  /// Registration step 1: ask the server to send a verification code.
  /// Endpoint spelling is inferred, not verified against a live account.
  Future<ApiResponse<void>> sendCode(
    String email,
    String password,
    String name,
  ) async {
    final raw = await _postForm('/eapi/user/send_code', {
      'email': email,
      'password': password,
      'name': name,
    });
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'send code failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'send code failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(null);
  }

  /// Registration step 2: verify the code. The app logs in separately
  /// afterwards, so this only reports success/failure.
  Future<ApiResponse<void>> verifyCode(
    String email,
    String password,
    String name,
    String code,
  ) async {
    final raw = await _postForm('/eapi/user/verify_code', {
      'email': email,
      'password': password,
      'name': name,
      'code': code,
    });
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'verify code failed',
          statusCode: raw.status);
    }
    if (!ZLibraryApiBase._isSuccess(raw.json!)) {
      return ApiResponse.fail(
        (raw.json!['error'] ?? raw.json!['message'])?.toString() ??
            'verify code failed',
        statusCode: raw.status,
      );
    }
    return ApiResponse.ok(null);
  }

  Future<ApiResponse<User>> getProfile() async {
    final raw = await _get('/eapi/user/profile');
    if (raw.json == null) {
      return ApiResponse.fail(raw.error ?? 'profile failed',
          statusCode: raw.status);
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        (json['error'] ?? json['message'])?.toString() ?? 'profile failed',
        statusCode: raw.status,
      );
    }
    final userJson = ZLibraryApiBase._userJson(json);
    if (userJson == null) {
      return ApiResponse.fail('profile response had no user',
          statusCode: raw.status);
    }
    return ApiResponse.ok(_withSessionKey(User.fromJson(userJson)));
  }

}
