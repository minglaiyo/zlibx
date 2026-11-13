// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/network_error.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
// Network error detection and user-friendly error handling
// Detects Cloudflare blocks, connectivity issues, and provides solutions

// Dart imports:
import 'dart:async';
import 'dart:io';

// Package imports:
import 'package:dio/dio.dart';

// Project imports:
import 'package:zlibx/services/external_logger.dart';

// Enum for categorized network error types
enum NetworkErrorType {
  noInternet,
  cloudflareBlock,
  serverUnavailable,
  timeout,
  forbidden,
  rateLimited,
  sslError,
  dnsError,
  unknown,
}

// Holds parsed error info with user-friendly message and solution
class NetworkError implements Exception {
  final NetworkErrorType type;
  final String userMessage;
  final String solution;
  final String? technicalDetails;
  final String? rawResponseBody;
  final String? blockedUrl; // URL that was blocked (for opening in browser)

  NetworkError({
    required this.type,
    required this.userMessage,
    required this.solution,
    this.technicalDetails,
    this.rawResponseBody,
    this.blockedUrl,
  });

  @override
  String toString() => "NetworkError.${type.name}";

  // Factory to create error from exception - performs additional diagnostics
  static Future<NetworkError> fromExceptionAsync(dynamic error,
      {String? responseBody, String? targetHost}) async {
    final logger = AppLogger();

    // An already-classified error passes through untouched. Re-wrapping
    // it used to turn e.g. a cloudflareBlock NetworkError into "unknown",
    // which stripped the type and the blockedUrl - and silently disabled
    // the webview capture that [searchBooks] and [bookInfo] gate on it.
    if (error is NetworkError) return error;

    // Log technical details for debugging
    logger.error(
      "Network error occurred",
      tag: "NetworkError",
      error: error,
      metadata: {
        "errorType": error.runtimeType.toString(),
        "hasResponseBody": responseBody != null,
        "targetHost": targetHost,
      },
    );

    // Handle TimeoutException - perform additional diagnostics
    if (error is TimeoutException) {
      return await _diagnoseTimeoutError(error, logger, targetHost);
    }

    // Handle DioException types
    if (error is DioException) {
      return _handleDioException(error, logger);
    }

    // Handle SocketException (no internet)
    if (error is SocketException) {
      return _diagnoseSocketException(error, logger);
    }

    // Handle HandshakeException (SSL/TLS issues)
    if (error is HandshakeException) {
      return NetworkError(
        type: NetworkErrorType.sslError,
        userMessage: "Secure connection failed",
        solution:
            "Your network may be blocking secure connections. Try using a VPN or different network.",
        technicalDetails: error.message,
      );
    }

    // Handle string-based socket exception marker. The comparison is
    // case-insensitive on purpose: SocketException.toString() renders
    // "SocketException: ..." (capital S), so a case-sensitive check
    // never matched and wrapped socket errors fell into "unknown".
    if (error.toString().toLowerCase().contains("socketexception")) {
      return NetworkError(
        type: NetworkErrorType.noInternet,
        userMessage: "Unable to access the internet",
        solution:
            "Check your internet connection. Make sure WiFi or mobile data is enabled.",
      );
    }

    // Handle timeout string markers
    if (error.toString().toLowerCase().contains("timeout")) {
      return await _diagnoseTimeoutError(error, logger, targetHost);
    }

    // Default unknown error
    return NetworkError(
      type: NetworkErrorType.unknown,
      userMessage: "Something went wrong",
      solution:
          "Please try again. If the problem persists, try restarting the app.",
      technicalDetails: error.toString(),
    );
  }

  // Diagnose timeout errors with connectivity checks
  static Future<NetworkError> _diagnoseTimeoutError(
      dynamic error, AppLogger logger, String? targetHost) async {
    logger.debug("Diagnosing timeout error", tag: "NetworkError");

    // Check if we have internet at all
    final hasInternet = await ConnectivityChecker.hasInternetConnection();

    if (!hasInternet) {
      logger.debug("No internet connection detected", tag: "NetworkError");
      return NetworkError(
        type: NetworkErrorType.noInternet,
        userMessage: "No internet connection",
        solution:
            "Your device is not connected to the internet.\n\n🔧 Check that:\n• WiFi or mobile data is enabled\n• Airplane mode is off\n• You have signal/coverage",
        technicalDetails: "Timeout + no internet connectivity detected",
      );
    }

    // Internet works, check if we can reach the target host
    if (targetHost != null) {
      final canReachHost = await ConnectivityChecker.canReachHost(targetHost);

      if (!canReachHost) {
        logger.debug("Cannot resolve host: $targetHost", tag: "NetworkError");
        return NetworkError(
          type: NetworkErrorType.dnsError,
          userMessage: "Cannot reach the server",
          solution:
              "The site \"$targetHost\" cannot be reached. Your ISP may be blocking it.\n\n🔧 Solutions:\n• Use a VPN (recommended)\n• Change DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network",
          technicalDetails: "Host unreachable: $targetHost",
        );
      }
    }

    // Can reach internet and host, but still timed out - server issue or throttling
    logger.debug("Internet OK but request timed out - likely server issue",
        tag: "NetworkError");
    return NetworkError(
      type: NetworkErrorType.timeout,
      userMessage: "Server not responding",
      solution:
          "The server is taking too long to respond.\n\n🔧 This could mean:\n• The server is overloaded\n• Your connection is being throttled\n• The site may be blocking your IP\n\nTry:\n• Use a VPN\n• Try again in a few minutes\n• Try a different mirror in Settings",
      technicalDetails: error.toString(),
    );
  }

  // Diagnose SocketException for specific issues
  static NetworkError _diagnoseSocketException(
      SocketException error, AppLogger logger) {
    final message = error.message.toLowerCase();
    final osErrorMessage = error.osError?.message.toLowerCase() ?? "";

    logger.debug("Diagnosing socket exception",
        tag: "NetworkError",
        metadata: {"message": message, "osError": osErrorMessage});

    // Host not found / DNS failure
    if (message.contains("host") ||
        message.contains("lookup") ||
        message.contains("getaddrinfo") ||
        osErrorMessage.contains("no address associated") ||
        osErrorMessage.contains("name or service not known")) {
      return NetworkError(
        type: NetworkErrorType.dnsError,
        userMessage: "Server not found",
        solution:
            "Cannot find the server. This usually means:\n\n• The site is blocked by your ISP\n• DNS resolution failed\n\n🔧 Solutions:\n• Use a VPN\n• Change DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network",
        technicalDetails: "DNS lookup failed: ${error.message}",
      );
    }

    // Connection refused
    if (message.contains("refused") || osErrorMessage.contains("refused")) {
      return NetworkError(
        type: NetworkErrorType.serverUnavailable,
        userMessage: "Connection refused",
        solution:
            "The server refused the connection. The service may be down or blocking requests.\n\n🔧 Try:\n• Use a VPN\n• Try a different mirror in Settings\n• Try again later",
        technicalDetails: "Connection refused: ${error.message}",
      );
    }

    // Connection reset
    if (message.contains("reset") || osErrorMessage.contains("reset")) {
      return NetworkError(
        type: NetworkErrorType.serverUnavailable,
        userMessage: "Connection was reset",
        solution:
            "The connection was interrupted. This could be:\n\n• Network instability\n• The server closed the connection\n• A firewall blocking the request\n\n🔧 Try:\n• Use a VPN\n• Check your internet connection\n• Try again",
        technicalDetails: "Connection reset: ${error.message}",
      );
    }

    // Network unreachable
    if (message.contains("unreachable") ||
        osErrorMessage.contains("unreachable")) {
      return NetworkError(
        type: NetworkErrorType.noInternet,
        userMessage: "Network unreachable",
        solution:
            "Cannot reach the network. Check your internet connection.\n\n🔧 Make sure:\n• WiFi or mobile data is connected\n• You have signal/coverage\n• No VPN is interfering",
        technicalDetails: "Network unreachable: ${error.message}",
      );
    }

    // Generic no internet
    return NetworkError(
      type: NetworkErrorType.noInternet,
      userMessage: "Connection failed",
      solution:
          "Unable to connect to the server.\n\n🔧 Check:\n• Your internet connection\n• WiFi or mobile data is enabled\n• Try using a VPN",
      technicalDetails: error.message,
    );
  }

  // Handle Dio-specific exceptions
  static NetworkError _handleDioException(
      DioException error, AppLogger logger) {
    final statusCode = error.response?.statusCode;
    final responseData = error.response?.data?.toString();

    // Log response for debugging
    logger.debug(
      "Dio exception details",
      tag: "NetworkError",
      metadata: {
        "type": error.type.toString(),
        "statusCode": statusCode,
        "message": error.message,
      },
    );

    // Check for Cloudflare challenge/block in response
    if (_isCloudflareBlock(error.response)) {
      final requestUrl = error.requestOptions.uri.toString();
      return NetworkError(
        type: NetworkErrorType.cloudflareBlock,
        userMessage: "Access blocked by DDoS protection",
        solution:
            "This site is protected and blocking your access.\n\n🔧 Solutions to try:\n• Use a VPN (recommended)\n• Change your DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network\n• Wait a few minutes and retry\n• Click 'Verify in Browser' to solve the captcha manually",
        technicalDetails: "DDoS challenge/block detected (HTTP $statusCode)",
        rawResponseBody: responseData,
        blockedUrl: requestUrl.isNotEmpty ? requestUrl : null,
      );
    }

    // Categorize by Dio exception type
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return NetworkError(
          type: NetworkErrorType.timeout,
          userMessage: "Connection timed out",
          solution:
              "The server is taking too long to respond. Check your internet speed or try again later.",
          technicalDetails: error.message,
        );

      case DioExceptionType.connectionError:
        // Check if it's a DNS resolution failure
        if (error.message?.contains("Failed host lookup") == true ||
            error.message?.contains("getaddrinfo") == true) {
          return NetworkError(
            type: NetworkErrorType.dnsError,
            userMessage: "Cannot reach the server",
            solution:
                "The site might be blocked by your ISP.\n\n🔧 Solutions:\n• Change DNS to 1.1.1.1 or 8.8.8.8\n• Use a VPN\n• Try a different network",
            technicalDetails: error.message,
          );
        }
        return NetworkError(
          type: NetworkErrorType.noInternet,
          userMessage: "Connection failed",
          solution:
              "Check your internet connection and try again. Make sure you're connected to WiFi or mobile data.",
          technicalDetails: error.message,
        );

      case DioExceptionType.badResponse:
        return _handleBadResponse(statusCode, responseData, error.message);

      case DioExceptionType.cancel:
        return NetworkError(
          type: NetworkErrorType.unknown,
          userMessage: "Request was cancelled",
          solution: "The operation was stopped. You can try again.",
          technicalDetails: "Request cancelled by user or system",
        );

      case DioExceptionType.unknown:
        // Check for specific socket/network errors
        if (error.error is SocketException) {
          return NetworkError(
            type: NetworkErrorType.noInternet,
            userMessage: "No internet connection",
            solution:
                "Unable to reach the internet. Check your connection and try again.",
            technicalDetails: (error.error as SocketException).message,
          );
        }
        return NetworkError(
          type: NetworkErrorType.unknown,
          userMessage: "Network error occurred",
          solution: "Please check your internet connection and try again.",
          technicalDetails: error.message ?? error.error?.toString(),
        );

      default:
        return NetworkError(
          type: NetworkErrorType.unknown,
          userMessage: "An unexpected error occurred",
          solution:
              "Please try again. If the problem continues, restart the app.",
          technicalDetails: error.message,
        );
    }
  }

  // Handle HTTP error status codes
  static NetworkError _handleBadResponse(
      int? statusCode, String? responseData, String? message) {
    // Check for Cloudflare in response body
    if (responseData != null && _containsCloudflareMarkers(responseData)) {
      return NetworkError(
        type: NetworkErrorType.cloudflareBlock,
        userMessage: "Access blocked by DDoS protection",
        solution:
            "This site is protected and blocking your access.\n\n🔧 Solutions to try:\n• Use a VPN (recommended)\n• Change your DNS to 1.1.1.1 or 8.8.8.8\n• Try a different network\n• Wait a few minutes and retry",
        technicalDetails: "HTTP $statusCode with DDoS protection markers",
        rawResponseBody: responseData,
      );
    }

    switch (statusCode) {
      case 403:
        return NetworkError(
          type: NetworkErrorType.forbidden,
          userMessage: "Access denied",
          solution:
              "You don't have permission to access this resource.\n\n🔧 Try:\n• Using a VPN\n• Changing your DNS settings\n• Trying a different mirror in Settings",
          technicalDetails: "HTTP 403 Forbidden",
          rawResponseBody: responseData,
        );

      case 429:
        return NetworkError(
          type: NetworkErrorType.rateLimited,
          userMessage: "Too many requests",
          solution:
              "You've made too many requests. Please wait a few minutes before trying again.",
          technicalDetails: "HTTP 429 Rate Limited",
        );

      case 500:
      case 502:
      case 503:
      case 504:
        return NetworkError(
          type: NetworkErrorType.serverUnavailable,
          userMessage: "Server is temporarily unavailable",
          solution:
              "The server is having issues. Try again in a few minutes or try a different mirror in Settings.",
          technicalDetails: "HTTP $statusCode Server Error",
        );

      case 451:
        // Unavailable for legal reasons - often geo-blocked
        return NetworkError(
          type: NetworkErrorType.forbidden,
          userMessage: "Content not available in your region",
          solution:
              "This content may be blocked in your region.\n\n🔧 Solutions:\n• Use a VPN to access from a different location\n• Try a different mirror in Settings",
          technicalDetails: "HTTP 451 Unavailable For Legal Reasons",
        );

      default:
        return NetworkError(
          type: NetworkErrorType.unknown,
          userMessage: "Server returned an error",
          solution:
              "Please try again. If the error persists, try a different mirror in Settings.",
          technicalDetails: "HTTP $statusCode - $message",
          rawResponseBody: responseData,
        );
    }
  }

  // Detect Cloudflare challenge or block
  static bool _isCloudflareBlock(Response<dynamic>? response) {
    if (response == null) return false;

    // Check cf-mitigated header (official Cloudflare detection)
    final headers = response.headers;
    if (headers.value("cf-mitigated") == "challenge") {
      return true;
    }

    final statusCode = response.statusCode;

    // 52x statuses are DDoS-Guard/Cloudflare's own error codes, so they
    // always indicate the providers' block page.
    if (statusCode != null && statusCode >= 520 && statusCode <= 524) {
      return true;
    }

    // Check for Cloudflare-specific server headers
    if (headers.value("server")?.toLowerCase().contains("cloudflare") == true) {
      return true;
    }

    // NOTE: a bare 403/503 is NOT treated as a challenge on its own.
    // Anna's Archive download mirrors honestly refuse with a plain 403
    // ("Link expired or invalid...") - mislabeling that as a DDoS block
    // used to route it into the webview solver, whose capture then
    // parsed into an empty "no results" instead of an honest error.
    // Without corroboration it is reported as a normal refusal.

    // Check response body for Cloudflare markers
    final body = response.data?.toString() ?? "";
    return _containsCloudflareMarkers(body);
  }

  // Check response body for Cloudflare challenge page markers
  static bool _containsCloudflareMarkers(String body) {
    final lowerBody = body.toLowerCase();

    // Common Cloudflare challenge page indicators
    final markers = [
      "checking your browser",
      "cloudflare",
      "cf-browser-verification",
      "cf_chl_prog",
      "just a moment",
      "enable javascript and cookies",
      "ray id:",
      "please wait while we verify",
      "ddos protection by",
      "attention required",
      "please complete the security check",
      "__cf_chl_tk",
      "turnstile",
      // DDoS-Guard and other providers
      "ddos-guard",
      "ddos guard",
      "checking if the site connection is secure",
      "needs to review the security of your connection",
      "verifying you are human",
      "please wait",
      "browser check",
      "security check",
      "verify you are human",
    ];

    for (final marker in markers) {
      if (lowerBody.contains(marker)) {
        return true;
      }
    }

    return false;
  }
}

// Extension to check internet connectivity
class ConnectivityChecker {
  static final AppLogger _logger = AppLogger();

  // Quick check if device can reach the internet
  static Future<bool> hasInternetConnection() async {
    try {
      // lookup() itself has no built-in timeout: on a broken/hijacked
      // DNS setup it can hang far longer than the user should wait for
      // an error message. Bound it explicitly.
      final result = await InternetAddress.lookup("google.com")
          .timeout(const Duration(seconds: 3));
      final hasConnection =
          result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      _logger.debug(
        "Internet connectivity check",
        tag: "Connectivity",
        metadata: {"hasConnection": hasConnection},
      );
      return hasConnection;
    } on SocketException {
      _logger.debug("No internet connection detected", tag: "Connectivity");
      return false;
    } catch (e) {
      _logger.debug(
        "Connectivity check failed",
        tag: "Connectivity",
        metadata: {"error": e.toString()},
      );
      return false;
    }
  }

  // Check if a specific host is reachable
  static Future<bool> canReachHost(String host) async {
    try {
      final uri = Uri.parse(host);
      final hostname = uri.host.isNotEmpty ? uri.host : host;
      // Same bounded lookup as [hasInternetConnection].
      final result = await InternetAddress.lookup(hostname)
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } catch (e) {
      return false;
    }
  }
}
