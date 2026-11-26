/// Z-Library error table (plan item 10): one place that turns a server
/// answer into a fixed category, so no call site guesses.
///
/// The envelope is parsed first — [zlibErrorText] pulls the human text
/// out of a plain string, a `{"error": ...}` / `{"message": ...}`
/// envelope, or a [DioException] (its response body, else its message)
/// — and [classifyZlibError] maps that text (and the status) onto a
/// kind. The rules, in order:
///
///  * 513 / 517 or a DiamWall marker → [ZlibErrorKind.switchDomain]:
///    the line itself is unusable, switch lines. No auto-switch: there
///    is no auto-switch mechanism in the app (switching is manual, via
///    the picker or `DomainNotifier.setDomain`), and silently moving the
///    user to another line needs a UX decision, not a classifier.
///  * `Access denied` / `拒绝访问` → [ZlibErrorKind.searchRefused]:
///    the request was refused. It is NOT a session verdict — it never
///    reads as "session expired" — and it never retries.
///  * `daily limit` → [ZlibErrorKind.quotaExhausted].
///  * `invalid credentials` / `please login` → [ZlibErrorKind.sessionExpired]:
///    the stored pair is no longer accepted.
///  * `incorrect email or password` / `authorization failed` →
///    [ZlibErrorKind.credentialError]: the credentials themselves are
///    wrong (a login-time answer), not a session verdict.
///  * 502 / 503 / 504 (any 5xx) → [ZlibErrorKind.serverRetryable]:
///    exponential backoff, at most 3 times.
///  * any other 4xx → [ZlibErrorKind.clientError]: never retried.
///
/// Message rules are checked before status rules, so a 403 that says
/// "Access denied" is a refusal, not a generic client error.
library;

import 'package:dio/dio.dart';

/// What a Z-Library failure is, per the plan-10 table. `unknown` means
/// nothing in the table matched — the caller falls back to its own
/// generic handling, it does not guess a kind.
enum ZlibErrorKind {
  /// The server refused the request (`Access denied` / `拒绝访问`).
  /// Not a session verdict, never retried.
  searchRefused,

  /// The account's daily quota is used up (`daily limit`).
  quotaExhausted,

  /// The stored session pair is no longer accepted.
  sessionExpired,

  /// The credentials themselves are wrong (login-time answer).
  credentialError,

  /// 513 / 517 or a DiamWall marker: this line is unusable, switch lines.
  switchDomain,

  /// A 5xx answer: retry with exponential backoff, at most 3 times.
  serverRetryable,

  /// Any other 4xx: a client-side failure, never retried.
  clientError,

  /// Nothing in the table matched.
  unknown,
}

/// Pull the human error text out of [error]: a plain string, a
/// `{"error": ...}` / `{"message": ...}` envelope, or a [DioException]
/// (its response body, else its own message). Anything else renders as
/// its `toString()`; null renders as `''`.
String zlibErrorText(Object? error) {
  if (error == null) return '';
  if (error is String) return error;
  if (error is DioException) {
    final body = error.response?.data;
    if (body != null) {
      final text = zlibErrorText(body);
      if (text.isNotEmpty) return text;
    }
    return error.message ?? '';
  }
  if (error is Map) {
    final value = error['error'] ?? error['message'];
    if (value == null) return '';
    return value.toString();
  }
  return error.toString();
}

/// Map a Z-Library failure onto the plan-10 table. [status] is the HTTP
/// status when the caller has it; when it is null, a status embedded in
/// the message text (`HTTP 513: ...`) is parsed out, so the table works
/// from either input.
ZlibErrorKind classifyZlibError({int? status, String? message}) {
  final m = (message ?? '').toLowerCase();
  final code = status ?? _httpStatus(m);
  // DiamWall / 513 / 517: the line itself is unusable.
  if (code == 513 ||
      code == 517 ||
      m.contains('diamwall')) {
    return ZlibErrorKind.switchDomain;
  }
  // A refused request is not a session verdict: it wins over every
  // session word below, and it never retries.
  if (m.contains('access denied') || m.contains('拒绝访问')) {
    return ZlibErrorKind.searchRefused;
  }
  if (m.contains('daily limit')) return ZlibErrorKind.quotaExhausted;
  if (m.contains('incorrect email or password') ||
      m.contains('authorization failed')) {
    return ZlibErrorKind.credentialError;
  }
  // Session verdicts: the positive list, guarded by the not-a-rejection
  // list — a busy mirror answering "too many requests, try again" must
  // not read as a bad password.
  if (!_notASessionRejection.any(m.contains) &&
      _sessionRejectionWords.any(m.contains)) {
    return ZlibErrorKind.sessionExpired;
  }
  if (code != null && code >= 500 && code < 600) {
    return ZlibErrorKind.serverRetryable;
  }
  if (code != null && code >= 400 && code < 500) {
    return ZlibErrorKind.clientError;
  }
  return ZlibErrorKind.unknown;
}

int? _httpStatus(String lowerMessage) {
  final match = RegExp(r'http\s+(\d{3})').firstMatch(lowerMessage);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Words that mean "this session pair is not acceptable".
///
/// Deliberately a narrow POSITIVE list, and the only place where a
/// server string may decide something about the credentials: callers
/// use it to choose a destructive action (drop the stored pair,
/// re-verify the session), so an unrecognised message costs a retry
/// while a false hit costs the user their password.
const _sessionRejectionWords = <String>[
  'invalid user',
  'invalid key',
  'invalid token',
  'invalid credentials',
  'userkey',
  'user key',
  'unauthorized',
  'unauthenticated',
  'not authorized',
  'not logged in',
  'login required',
  'please login',
  'please log in',
  'wrong password',
  'bad login',
  'expired',
  'permission denied',
];

/// Rejections of the REQUEST, not of the session. They win over the list
/// above: a busy mirror answering "too many requests, try again" must not
/// read as a bad password.
const _notASessionRejection = <String>[
  'too many',
  'frequent',
  'rate limit',
  'captcha',
  'try again',
  'temporarily',
  'maintenance',
  'slow down',
];
