import 'package:hive_flutter/hive_flutter.dart';

class HiveService {
  static const String settingsBoxName = 'settings';
  static const String authBoxName = 'auth';
  static const String booklistHtmlBoxName = 'booklist_html';
  static const String viewHistoryBoxName = 'view_history';

  /// Opens the boxes the app needs BEFORE the first frame: settings and
  /// auth. Both are small and several startup paths read them
  /// synchronously, so they must be ready before `runApp`.
  static Future<void> init() async {
    await Hive.initFlutter();
    await Future.wait([
      Hive.openBox(settingsBoxName),
      Hive.openBox(authBoxName),
    ]);
  }

  /// Opens the two heavier, non-critical-for-first-frame boxes AFTER
  /// the first frame (O2). view_history is a regular Box: it holds
  /// ≤200 small book-JSON rows and several read paths (search
  /// suggestions included) hit it synchronously. booklist_html is a
  /// [LazyBox] (审查1 P-2 / 审查3 P3-1 落地): its values are up to ~20 MB
  /// of page HTML, and a regular Box parses EVERY value into memory at
  /// open. LazyBox keeps only the key index; values read from disk on
  /// demand (`get` is async in hive 2.2.3, which is why the cache API
  /// went Future around it). Frame files are format-compatible between
  /// the two views, so the box keeps its name and old entries load
  /// without migration.
  static Future<void> initSecondary() async {
    await Future.wait([
      Hive.openLazyBox(booklistHtmlBoxName),
      Hive.openBox(viewHistoryBoxName),
    ]);
  }

  static Box<dynamic> get settingsBox => Hive.box(settingsBoxName);
  static Box<dynamic> get authBox => Hive.box(authBoxName);
  static LazyBox<dynamic> get booklistHtmlBox => Hive.lazyBox(booklistHtmlBoxName);
  static Box<dynamic> get viewHistoryBox => Hive.box(viewHistoryBoxName);
}
