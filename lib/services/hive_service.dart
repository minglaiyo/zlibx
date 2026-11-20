import 'package:hive_flutter/hive_flutter.dart';

class HiveService {
  static const String settingsBoxName = 'settings';
  static const String authBoxName = 'auth';
  static const String booklistHtmlBoxName = 'booklist_html';
  static const String viewHistoryBoxName = 'view_history';

  /// 业务数据库（审查 A1，2026-11-20）：收藏 / 下载历史（A2 逐条键）/
  /// 服务端历史缓存 / 详情附加元数据 / 已下载元数据。首帧后才开
  /// （[initSecondary]），settings 只留偏好项与必须在首帧前同步读的
  /// 小键（启动缓存、疲劳名单）。打开前这些数据的同步读走
  /// settingsBox 回退（迁移尚未跑，旧值还在那），异步写直接提前开盒
  /// （[libraryBoxAsync]），迁移对已存在的键不覆盖——三个方向都不会
  /// 丢写。
  static const String libraryBoxName = 'library';

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

  /// Opens the heavier, non-critical-for-first-frame boxes AFTER
  /// the first frame (O2). view_history is a regular Box: it holds
  /// ≤200 small book-JSON rows and several read paths (search
  /// suggestions included) hit it synchronously. booklist_html is a
  /// [LazyBox] (审查1 P-2 / 审查3 P3-1 落地): its values are up to ~20 MB
  /// of page HTML, and a regular Box parses EVERY value into memory at
  /// open. LazyBox keeps only the key index; values read from disk on
  /// demand (`get` is async in hive 2.2.3, which is why the cache API
  /// went Future around it). Frame files are format-compatible between
  /// the two views, so the box keeps its name and old entries load
  /// without migration. library 是同一代的第三个：值都是小 Map / 列表，
  /// 常规 Box 的内存代价可接受，同步读路径多。
  static Future<void> initSecondary() async {
    await Future.wait([
      Hive.openLazyBox(booklistHtmlBoxName),
      Hive.openBox(viewHistoryBoxName),
      libraryBoxAsync(),
    ]);
  }

  static Future<Box<dynamic>>? _libraryOpening;

  /// library 盒的异步入口：已开直返；首帧前的写调用会提前开盒（迁移
  /// 对已存在的键不覆盖，所以提前写不会被旧值回滚）。开盒失败要清掉
  /// 缓存的 Future——否则一次失败（测试里 Hive 没 init、真机上磁盘
  /// 瞬断）会把毒 Future 留给之后每一次调用。
  static Future<Box<dynamic>> libraryBoxAsync() async {
    if (Hive.isBoxOpen(libraryBoxName)) {
      return Hive.box(libraryBoxName);
    }
    final opening = _libraryOpening ??= Hive.openBox(libraryBoxName)
        .catchError((Object error) {
          _libraryOpening = null;
          return Future<Box<dynamic>>.error(error);
        });
    await opening;
    return Hive.box(libraryBoxName);
  }

  static bool get isLibraryOpen => Hive.isBoxOpen(libraryBoxName);

  /// 已开前提下的直取 getter（测试与迁移后路径用）；未开抛 HiveError,
  /// 首帧前窗口请用 [libraryBoxOrNull] / [libraryBoxAsync]。
  static Box<dynamic> get libraryBox => Hive.box(libraryBoxName);

  /// 同步读入口：盒没开时返回 null（调用方各自有优雅默认值）。
  static Box<dynamic>? get libraryBoxOrNull =>
      isLibraryOpen ? Hive.box(libraryBoxName) : null;

  static Box<dynamic> get settingsBox => Hive.box(settingsBoxName);
  static Box<dynamic> get authBox => Hive.box(authBoxName);
  static LazyBox<dynamic> get booklistHtmlBox => Hive.lazyBox(booklistHtmlBoxName);
  static Box<dynamic> get viewHistoryBox => Hive.box(viewHistoryBoxName);
}
