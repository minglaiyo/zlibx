/// Generic wrapper for one Z-Library API call.
///
/// The app only reads [success], [data], [error] and [meta]:
/// - `search` / `getUserSaved` read `meta['total_pages']` for pagination.
/// - auth code treats `error == 'cf_blocked'` (and transient network
///   substrings) specially, so error strings are kept stable, see
///   `zlibrary_api.dart`.
class ApiResponse<T> {
  final bool success;
  final T? data;
  final String? error;
  final int? statusCode;

  /// True only when the server looked at the credentials the call carried
  /// and refused them: an HTTP 401, or a JSON `success: 0` answer whose own
  /// message rejects the session.
  ///
  /// Everything the transport can produce without judging the pair — wall
  /// page, 5xx, 429, empty or non-JSON body, a payload with no user object,
  /// a message-less `success: 0`, a cancelled request — leaves this false.
  /// The app deletes stored credentials only on a real rejection (see
  /// `lib/providers/auth_provider.dart`), so a wrong `true` costs the user
  /// their password while a wrong `false` only costs a retry.
  final bool authRejected;

  /// Pagination / extra fields from the server, e.g. `{'total_pages': 12}`.
  /// Kept as the raw map so callers can read keys the server adds later.
  final Map<String, dynamic>? meta;

  const ApiResponse({
    required this.success,
    this.data,
    this.error,
    this.statusCode,
    this.meta,
    this.authRejected = false,
  });

  factory ApiResponse.ok(T data, {Map<String, dynamic>? meta}) =>
      ApiResponse(success: true, data: data, meta: meta);

  factory ApiResponse.fail(
    String error, {
    int? statusCode,
    bool authRejected = false,
  }) =>
      ApiResponse(
        success: false,
        error: error,
        statusCode: statusCode,
        authRejected: authRejected,
      );
}
