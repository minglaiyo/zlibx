import 'package:hive_flutter/hive_flutter.dart';

class HiveService {
  static const String settingsBoxName = 'settings';
  static const String authBoxName = 'auth';
  static const String booklistHtmlBoxName = 'booklist_html';
  static const String viewHistoryBoxName = 'view_history';

  static Future<void> init() async {
    await Hive.initFlutter();
    // 四个 box 互不依赖，并行打开（此前串行，启动链路多等两轮
    // 磁盘 IO）。
    await Future.wait([
      Hive.openBox(settingsBoxName),
      Hive.openBox(authBoxName),
      Hive.openBox(booklistHtmlBoxName),
      Hive.openBox(viewHistoryBoxName),
    ]);
  }

  static Box<dynamic> get settingsBox => Hive.box(settingsBoxName);
  static Box<dynamic> get authBox => Hive.box(authBoxName);
  static Box<dynamic> get booklistHtmlBox => Hive.box(booklistHtmlBoxName);
  static Box<dynamic> get viewHistoryBox => Hive.box(viewHistoryBoxName);
}
