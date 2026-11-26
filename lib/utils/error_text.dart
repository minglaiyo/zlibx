import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/generated/app_localizations.dart';

/// 错误文案本地化目录（审查遗留项：此前 5 处界面直接显示
/// `error.toString()`，用户看到的是 "Bad state: timeout: ..." 这类
/// 带前缀的英文技术文本）。
///
/// 数据源的错误文本主要有两类：
/// 1. 插件 `_fromError` 映射出的短语（'timeout: …'、
///    'connection error: …'、'HTTP 403: …'、'cf_blocked'、
///    'HTTP 403: browser check page'、'cancelled'），经 provider 的
///    `StateError` 包裹后带 "Bad state: " 前缀到达界面；
/// 2. 平台层异常（OpenFilex / Hive / FormatException 等）。
///
/// 这里按模式匹配常见形态翻成本地化文案；匹配不上的（ novel 平台
/// 错误）去掉前缀、截断后原样展示——保留可诊断性，但不泄漏长 HTML。
///
/// 计划一第 10 项：Z-Library 的错误先过分类表
/// ([classifyZlibError])。`isSearchError` 为真时（搜索页的错误），
/// 一个被拒的请求（"Access denied"）显示"Z-library 拒绝搜索"；别的
/// 界面不传它——一个打开文件的平台错误也可能说 "access denied"，
/// 那不是搜索被拒。切域（513/517/DiamWall）与额度（daily limit）
/// 在哪都是一回事，不用区分。
String friendlyErrorText(
  Object? error,
  AppLocalizations l10n, {
  bool isSearchError = false,
}) {
  var text = error?.toString() ?? '';
  for (final prefix in const [
    'Bad state: ',
    'Exception: ',
    'FormatException: ',
    'StateError: ',
    'DownloadContentException: ',
    'DownloadTruncatedException: ',
    'DownloadMagicException: ',
  ]) {
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
  }
  if (text.trim().isEmpty) return l10n.errorGeneric;

  final lower = text.toLowerCase();

  // 计划一第 10 项：分类表先定性。搜索被拒不当作会话过期、不重试；
  // 513/517/DiamWall 是线路不可用；daily limit 是额度。
  switch (classifyZlibError(message: text)) {
    case ZlibErrorKind.searchRefused:
      if (isSearchError) return l10n.searchRefused;
      break;
    case ZlibErrorKind.switchDomain:
      return l10n.errorSwitchLine;
    case ZlibErrorKind.quotaExhausted:
      return l10n.downloadQuotaExceeded;
    case ZlibErrorKind.sessionExpired:
    case ZlibErrorKind.credentialError:
    case ZlibErrorKind.serverRetryable:
    case ZlibErrorKind.clientError:
    case ZlibErrorKind.unknown:
      break;
  }

  // 浏览器验证墙（cf_blocked / challenge page）。
  if (lower.contains('cf_blocked') || lower.contains('browser check')) {
    return l10n.errorBlocked;
  }
  // 超时（plugin 形如 'timeout: …'；Dio 文本形如 '... timed out'）。
  if (lower.startsWith('timeout:') ||
      lower.contains('timeout') ||
      lower.contains('timed out')) {
    return l10n.errorTimeout;
  }
  // 连不上网（DNS / 无路由 / 拒绝 / 重置 / socket 层）。
  if (lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('connection error') ||
      lower.contains('no internet') ||
      lower.contains('socketexception')) {
    return l10n.errorNoConnection;
  }
  // 服务器侧 5xx。
  if (RegExp(r'http 5\d\d').hasMatch(lower)) {
    return l10n.errorServerError;
  }
  // 其余带状态码的（404 等）与未知错误：给通用文案。
  if (RegExp(r'http \d{3}').hasMatch(lower)) {
    return l10n.errorGeneric;
  }
  if (lower == 'cancelled') return l10n.errorGeneric;

  // 未知错误：保留原文（截断，避免整页 HTML 进 UI）。
  final cleaned = text.trim();
  return cleaned.length > 200 ? '${cleaned.substring(0, 200)}…' : cleaned;
}
