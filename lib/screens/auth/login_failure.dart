/// Login failure kinds, for the login screen's error dialog.
/// The server's messages are the only signal, so the split follows
/// what the server actually says — see [classifyLoginFailure].
enum LoginFailureKind {
  /// Network / line problem (unreachable, timeout, handshake, the
  /// mirror blocking the request). Not an account problem: the
  /// login screen offers switching lines.
  network,

  /// The credentials were refused: wrong password, or the
  /// email/password pair does not match any account.
  wrongPassword,

  /// The account itself does not exist / is not registered.
  accountError,

  /// Anything else (including server-side login restrictions that
  /// are not a password problem). Shown with the full detail so the
  /// user can report it.
  other,
}

/// The "empty error payload" placeholder is localized by the caller
/// ([noDetailText], `loginNoErrorDetail` in the ARBs): this file stays
/// UI-free, and the old hardcoded bilingual literal showed Simplified
/// Chinese to every locale (UI review finding 3).
String safeLoginErrorDetail(
  String? error,
  String email,
  String password, {
  required String noDetailText,
}) {
  if (error == null || error.trim().isEmpty) {
    return noDetailText;
  }

  var detail = error.trim();
  if (password.isNotEmpty) detail = detail.replaceAll(password, '[redacted]');
  if (email.isNotEmpty) detail = detail.replaceAll(email, '[redacted]');
  detail = detail.replaceAll(
    RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
    '[redacted email]',
  );
  detail = detail.replaceAll(
    RegExp(r'\bBearer\s+\S+', caseSensitive: false),
    'Bearer [redacted]',
  );
  detail = detail.replaceAllMapped(
    RegExp(
      r'''((?:password|passwd|token|secret|authorization|cookie|remix_userkey|remix_userid|userkey|userid)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)''',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}[redacted]',
  );
  detail = detail.replaceAll(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    '[URL redacted]',
  );

  return detail.length > 300 ? '${detail.substring(0, 300)}…' : detail;
}

LoginFailureKind classifyLoginFailure(String? error) {
  if (error == null || error.trim().isEmpty) {
    return LoginFailureKind.other;
  }

  final value = error.toLowerCase();
  if (value.contains('cf_blocked') ||
      value.contains('line_error') ||
      value.contains('timeout') ||
      value.contains('socket') ||
      value.contains('connection') ||
      value.contains('network') ||
      value.contains('handshake') ||
      value.contains('unreachable') ||
      value.contains('failed host lookup') ||
      value.contains('request failed')) {
    return LoginFailureKind.network;
  }

  final normalized = value.replaceAll('_', ' ');
  const accountMessages = [
    'user not found',
    'user not registered',
    'account not found',
    'account does not exist',
    'user does not exist',
  ];
  if (accountMessages.any(normalized.contains) ||
      value.contains('用户未注册') ||
      value.contains('账号不存在') ||
      value.contains('用户不存在') ||
      value.contains('账号未注册')) {
    return LoginFailureKind.accountError;
  }

  // "Authorization failed" is the eapi login endpoint's own refusal
  // (HTTP 400). The eapi research notes it is a separate control on
  // the login endpoint and does not by itself prove the password is
  // wrong — but in this app it is what the endpoint returns when the
  // password is rejected, so it is classified as a password error
  // rather than the vague "unknown" dialog. If the password is
  // confirmed correct and this still appears, it is the endpoint
  // refusing the account (try another line, or log in via browser).
  const passwordMessages = [
    'incorrect email or password',
    'invalid email or password',
    'email or password is incorrect',
    'incorrect password',
    'invalid password',
    'wrong password',
    'authorization failed',
    'incorrect credentials',
    'invalid credentials',
  ];
  if (passwordMessages.any(normalized.contains) ||
      value.contains('账号或密码错误') ||
      value.contains('账号密码错误') ||
      value.contains('邮箱或密码错误') ||
      value.contains('密码错误')) {
    return LoginFailureKind.wrongPassword;
  }

  return LoginFailureKind.other;
}
