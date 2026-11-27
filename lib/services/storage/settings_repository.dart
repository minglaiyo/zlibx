import '../hive_service.dart';
import 'storage_keys.dart';

/// Theme mode + download path settings, split out of
/// `storage_service.dart` (P1-4). Moved verbatim; no behavior change,
/// no key-name change.
class SettingsRepository {
  /// Get theme mode (0: system, 1: light, 2: dark)
  Future<int> getThemeMode() async {
    return HiveService.settingsBox.get(kThemeModeKey, defaultValue: 0) as int;
  }

  /// Set theme mode
  Future<void> setThemeMode(int mode) async {
    await HiveService.settingsBox.put(kThemeModeKey, mode);
  }

  /// Get download path
  Future<String?> getDownloadPath() async {
    return HiveService.settingsBox.get(kDownloadPathKey) as String?;
  }

  /// Set download path
  Future<void> setDownloadPath(String path) async {
    await HiveService.settingsBox.put(kDownloadPathKey, path);
  }
}
