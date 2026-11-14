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

  /// Opens the two heavier, non-critical-for-first-frame boxes
  /// (booklist_html, view_history) AFTER the first frame (O2). A regular
  /// Hive Box loads every value into memory when it opens — booklist_html
  /// can hold up to ~20 MB of cached HTML, which would delay the first
  /// frame and spike the Dart heap. Opening them after the first frame
  /// keeps the splash paint instant. Callers treat an unopened box as a
  /// cache miss: BooklistHtmlCache guards every access, and
  /// ViewHistoryStore already wraps every access in try/catch.
  static Future<void> initSecondary() async {
    await Future.wait([
      Hive.openBox(booklistHtmlBoxName),
      Hive.openBox(viewHistoryBoxName),
    ]);
  }

  static Box<dynamic> get settingsBox => Hive.box(settingsBoxName);
  static Box<dynamic> get authBox => Hive.box(authBoxName);
  static Box<dynamic> get booklistHtmlBox => Hive.box(booklistHtmlBoxName);
  static Box<dynamic> get viewHistoryBox => Hive.box(viewHistoryBoxName);
}
