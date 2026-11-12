import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/storage_service.dart';
import '../services/hive_service.dart';
import '../utils/locale_utils.dart';

enum AppThemeMode {
  system,
  light,
  dark,
}

/// Theme mode notifier
class ThemeModeNotifier extends Notifier<AppThemeMode> {
  late final StorageService _storage;

  @override
  AppThemeMode build() {
    _storage = ref.read(storageServiceProvider);
    _loadThemeMode();
    return AppThemeMode.system;
  }

  Future<void> _loadThemeMode() async {
    final mode = await _storage.getThemeMode();
    // Persisted values can be out of range after an enum change or a
    // corrupted settings box: AppThemeMode.values[mode] would throw an
    // uncaught RangeError inside this async gap and the theme would
    // silently stay on `system` forever. Clamp instead (clamp() returns
    // num, so round-trip through toInt() for the list index).
    final index =
        mode.clamp(0, AppThemeMode.values.length - 1).toInt();
    state = AppThemeMode.values[index];
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
  late final StorageService _storage;

  @override
  String? build() {
    _storage = ref.read(storageServiceProvider);
    _init();
    return null;
  }
  
  Future<void> _init() async {
    state = await _storage.getDownloadPath();
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

/// Whether the bottom nav bar is currently visible. Driven by the home
/// grid's scroll direction (transient UI state, not persisted).
class NavBarVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setVisible(bool value) => state = value;
}

final navBarVisibleProvider =
    NotifierProvider<NavBarVisibleNotifier, bool>(NavBarVisibleNotifier.new);
