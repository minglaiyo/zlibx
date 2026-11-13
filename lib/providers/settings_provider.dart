import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_lock_service.dart';
import '../services/storage_service.dart';
import '../services/hive_service.dart';
import '../utils/diagnostics.dart';
import '../utils/locale_utils.dart';

enum AppThemeMode {
  system,
  light,
  dark,
}

/// Theme mode notifier
class ThemeModeNotifier extends Notifier<AppThemeMode> {
  // Getter, not `late final`: ref.invalidate() re-runs build() on the
  // same instance, and a second assignment to a late final throws
  // LateInitializationError (the trap documented on books_provider /
  // download_provider).
  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  AppThemeMode build() => _loadThemeMode();

  /// Sync Hive read; returns the persisted mode as the initial state
  /// instead of assigning it (see LocaleNotifier). Reading it here
  /// (instead of defaulting to `system` and loading async) means the
  /// first frame already uses the user's theme — no flash.
  AppThemeMode _loadThemeMode() {
    final v = HiveService.settingsBox.get('theme_mode');
    // Persisted values can be out of range after an enum change or a
    // corrupted settings box: AppThemeMode.values[mode] would throw an
    // uncaught RangeError and the theme would silently stay on `system`
    // forever. Clamp instead (clamp() returns num, so round-trip
    // through toInt() for the list index).
    final index = v is int
        ? v.clamp(0, AppThemeMode.values.length - 1).toInt()
        : 0;
    return AppThemeMode.values[index];
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    state = mode;
    await _storage.setThemeMode(mode.index);
  }

}

/// Theme mode provider
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, AppThemeMode>(ThemeModeNotifier.new);

/// Download path notifier for custom download directory (Android only)
class DownloadPathNotifier extends Notifier<String?> {
  // Getter, not `late final` (see ThemeModeNotifier).
  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  String? build() => _loadDownloadPath();

  /// Sync Hive read; returns the persisted path as the initial state
  /// instead of assigning it (see LocaleNotifier). An empty string
  /// means "cleared" (see clearDownloadPath), so it reads as null.
  String? _loadDownloadPath() {
    final v = HiveService.settingsBox.get('download_path');
    return v is String && v.isNotEmpty ? v : null;
  }

  Future<void> setDownloadPath(String path) async {
    await _storage.setDownloadPath(path);
    state = path;
  }

  Future<void> clearDownloadPath() async {
    // Clear by setting empty string, storage will handle deletion
    await _storage.setDownloadPath('');
    state = null;
  }
}

/// Download path provider
final downloadPathProvider =
    NotifierProvider<DownloadPathNotifier, String?>(DownloadPathNotifier.new);

/// Locale notifier for managing app language
class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() => _loadLocale();

  /// Sync Hive read; returns the persisted locale as the initial state
  /// instead of assigning it (a state assignment inside build() would
  /// be overwritten by build()'s return value).
  Locale? _loadLocale() {
    final key = HiveService.settingsBox.get('locale');
    if (key != null && key is String) {
      return parseLocaleKey(key);
    }
    return null;
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    if (locale == null) {
      await HiveService.settingsBox.delete('locale');
    } else {
      await HiveService.settingsBox.put('locale', getLocaleKey(locale));
    }
  }

}

/// Locale provider
final localeProvider =
    NotifierProvider<LocaleNotifier, Locale?>(LocaleNotifier.new);

/// Blur effect notifier — whether the glass header and bottom nav bar use
/// a backdrop blur (on) or a solid surface (off). Default on.
class BlurNotifier extends Notifier<bool> {
  @override
  bool build() => _loadBlurEnabled();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _loadBlurEnabled() {
    final v = HiveService.settingsBox.get('blurEnabled');
    if (v is bool) return v;
    return true;
  }

  Future<void> setBlurEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('blurEnabled', value);
  }
}

/// Blur effect provider
final blurEnabledProvider =
    NotifierProvider<BlurNotifier, bool>(BlurNotifier.new);

/// Floating navigation bar — whether the bottom nav bar floats as a
/// detached rounded pill (on) or spans the full width attached to the
/// bottom edge (off). Default on.
class FloatingNavNotifier extends Notifier<bool> {
  @override
  bool build() => _loadFloatingNav();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _loadFloatingNav() {
    final v = HiveService.settingsBox.get('floatingNav');
    if (v is bool) return v;
    return true;
  }

  Future<void> setFloatingNav(bool value) async {
    state = value;
    await HiveService.settingsBox.put('floatingNav', value);
  }
}

/// Floating navigation bar provider
final floatingNavProvider =
    NotifierProvider<FloatingNavNotifier, bool>(FloatingNavNotifier.new);

/// Hide the floating nav bar on scroll down — whether the floating bar
/// slides away while scrolling down and returns on scroll up. Only
/// applies while the floating bar is on. Default on.
class HideNavOnScrollNotifier extends Notifier<bool> {
  @override
  bool build() => _loadHideNavOnScroll();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _loadHideNavOnScroll() {
    final v = HiveService.settingsBox.get('hideNavOnScroll');
    if (v is bool) return v;
    return true;
  }

  Future<void> setHideNavOnScroll(bool value) async {
    state = value;
    await HiveService.settingsBox.put('hideNavOnScroll', value);
  }
}

/// Hide-on-scroll provider
final hideNavOnScrollProvider =
    NotifierProvider<HideNavOnScrollNotifier, bool>(
      HideNavOnScrollNotifier.new,
    );

/// 推荐页四列布局 — whether the home recommendation grid renders a
/// fixed four-column layout (on) or the width-adaptive layout (off,
/// default). Appearance setting; lives in the appearance sheet.
class HomeGridFourColumnsNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _load() {
    final v = HiveService.settingsBox.get('homeGridFourColumns');
    if (v is bool) return v;
    return false;
  }

  Future<void> setFourColumns(bool value) async {
    state = value;
    await HiveService.settingsBox.put('homeGridFourColumns', value);
  }
}

/// 推荐页四列布局 provider
final homeGridFourColumnsProvider =
    NotifierProvider<HomeGridFourColumnsNotifier, bool>(
      HomeGridFourColumnsNotifier.new,
    );

/// 首页随机推荐 — whether the home feed shows random-category
/// recommendations (on) or the personalised recommendations (off).
/// Default off: the random path needs the category HTML route, which
/// can be walled on some lines (home shows an error then); off keeps
/// the previously working personalised feed. Hive key
/// `randomRecommend`.
class RandomRecommendNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _load() {
    final v = HiveService.settingsBox.get('randomRecommend');
    if (v is bool) return v;
    return false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('randomRecommend', value);
  }
}

/// 首页随机推荐 provider
final randomRecommendProvider =
    NotifierProvider<RandomRecommendNotifier, bool>(
      RandomRecommendNotifier.new,
    );

/// ── 隐私锁（用户批 2026-11-14 功能）─────────────────────────────
///
/// 三个持久化设置：启用开关、锁定时机（秒）、最近任务遮蔽（
/// FLAG_SECURE）。锁定状态本身是运行时状态，见
/// `lib/services/app_lock_service.dart` 的 AppLockController。
class AppLockEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  bool _load() {
    final v = HiveService.settingsBox.get('appLockEnabled');
    if (v is bool) return v;
    return false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('appLockEnabled', value);
  }
}

final appLockEnabledProvider =
    NotifierProvider<AppLockEnabledNotifier, bool>(
      AppLockEnabledNotifier.new,
    );

/// 切后台多少秒后要求解锁：0 = 立即，60 / 300 = 延迟。
class AppLockTimeoutNotifier extends Notifier<int> {
  @override
  int build() => _load();

  int _load() {
    final v = HiveService.settingsBox.get('appLockTimeoutSeconds');
    if (v is int && (v == 0 || v == 60 || v == 300)) return v;
    return 0;
  }

  Future<void> setTimeout(int seconds) async {
    state = seconds;
    await HiveService.settingsBox.put('appLockTimeoutSeconds', seconds);
  }
}

final appLockTimeoutProvider =
    NotifierProvider<AppLockTimeoutNotifier, int>(
      AppLockTimeoutNotifier.new,
    );

class SecureFlagNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  bool _load() {
    final v = HiveService.settingsBox.get('secureRecents');
    if (v is bool) return v;
    return false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('secureRecents', value);
    // 窗口旗标跟着开关走；失败只记录（旗标是隐私增强，不是功能闸）。
    await AppLockController.applySecureFlag(value);
  }
}

final secureFlagProvider =
    NotifierProvider<SecureFlagNotifier, bool>(SecureFlagNotifier.new);

/// 无痕模式：开启后不记录浏览历史（app_routes 的详情入口）和搜索
/// 记录（search_screen 的最近搜索）。历史/记录页照常显示旧内容，
/// 只是不再新增。
class IncognitoModeNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  bool _load() {
    final v = HiveService.settingsBox.get('incognitoMode');
    if (v is bool) return v;
    return false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('incognitoMode', value);
  }
}

final incognitoModeProvider =
    NotifierProvider<IncognitoModeNotifier, bool>(
      IncognitoModeNotifier.new,
    );

/// 详情页快捷入口上移开关：开启后相似书籍 / 加入书单 / 评论三行
/// 提到标题正下方（首屏直达）；关闭时保持页面底部原位置。简介与
/// 出版信息始终正常显示（用户批 2026-11-14 两轮调整后的最终语义）。
class DetailQuickActionsUpNotifier extends Notifier<bool> {
  @override
  bool build() => _load();

  /// Sync Hive read; returns the persisted value as the initial state
  /// instead of assigning it (see LocaleNotifier).
  bool _load() {
    try {
      final v = HiveService.settingsBox.get('detailQuickActionsUp');
      if (v is bool) return v;
    } catch (e) {
      // Hive box not open: the detail page (unlike the settings UI)
      // watches this provider, and widget tests build it without
      // opening Hive. Production always opens boxes in main(), so
      // this only ever fires in tests — default off there.
      logIgnored('settings_provider', e);
      return false;
    }
    return false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await HiveService.settingsBox.put('detailQuickActionsUp', value);
  }
}

/// 详情页快捷入口上移 provider
final detailQuickActionsUpProvider =
    NotifierProvider<DetailQuickActionsUpNotifier, bool>(
      DetailQuickActionsUpNotifier.new,
    );

/// Whether the bottom nav bar is currently visible. Driven by the home
/// grid's scroll direction (transient UI state, not persisted).
class NavBarVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setVisible(bool value) => state = value;
}

final navBarVisibleProvider =
    NotifierProvider<NavBarVisibleNotifier, bool>(NavBarVisibleNotifier.new);
