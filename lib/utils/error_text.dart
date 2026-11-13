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
String friendlyErrorText(Object? error, AppLocalizations l10n) {
  var text = error?.toString() ?? '';
  for (final prefix in const [
    'Bad state: ',
    'Exception: ',
    'FormatException: ',
    'StateError: ',
    'DownloadContentException: ',
    'DownloadTruncatedException: ',
  ]) {
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
  }
  if (text.trim().isEmpty) return l10n.errorGeneric;

  final lower = text.toLowerCase();

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
