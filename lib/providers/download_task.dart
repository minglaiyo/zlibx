// Download task model, split out of download_provider.dart.
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../models/display_book.dart';

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  error,
  cancelled,
}

class DownloadTask {
  final String id;
  final Book book;
  final double progress;
  final DownloadStatus status;
  final String? filePath;
  final String? error;
  final DateTime? downloadedAt;
  final int? fileSize;
  final bool needsFreshLink;
  final bool missingFile;

  /// 用户自己 Z 站账号当日下载次数已用尽导致的失败。
  final bool quotaExceeded;

  /// 计划一第 8 项（下载魔数校验）：下到的字节不是这本书宣称的格式
  ///（PDF 当 EPUB 下回来、续传前缀不对、完工文件头不对）。任务进
  /// 错误态，.part 已删，用户手动重试从零开始；canRetry 不变
  ///（needsFreshLink 仍为 false，同一条链接可重试）。
  final bool magicMismatch;

  /// 仅 Wi-Fi 下载（方案 E1）：发起时网络是计费连接（移动数据/无网），
  /// 任务被拒绝启动。到 Wi-Fi 后重试即可。
  final bool wifiOnlyBlocked;

  /// 下载队列置顶（方案 E2）：pending 任务被用户置顶，排在其他等待
  /// 任务之前。瞬时意图（重启后队列重建，不持久化）。
  final bool pinned;

  /// 外部源直链（Anna/LibGen 解析出的 URL）。暂停后恢复要用同一个
  /// 入口重跑下载流程；z 站任务为 null。
  final String? presetUrl;

  /// 这本书是从哪个源下的（#143 下载记录标注来源）：z 站 / Anna /
  /// LibGen。创建任务时由调用方写死；旧历史记录没存这个字段，读回
  /// 来是 null，下载页就不标（不猜——文件名反解分不清 z 书和外部
  /// 书，两者的 id 都是数字）。
  final BookSource? source;

  /// 这本书指定的下载子文件夹（#95 按书指定下载位置）：`Download/zlibx`
  /// 下的子文件夹名，由用户在详情页长按下载按钮指定。null = 用分
  /// 类模式默认的（按作者/按分类/平铺）。创建任务时写死，恢复/重
  /// 试沿用；旧历史记录没存这个字段，读回来是 null。
  final String? customSubfolder;

  bool get canRetry =>
      (status == DownloadStatus.error || status == DownloadStatus.cancelled) &&
      !needsFreshLink &&
      !missingFile &&
      book.id > 0 &&
      (book.hash?.isNotEmpty ?? false);

  const DownloadTask({
    required this.id,
    required this.book,
    this.progress = 0.0,
    this.status = DownloadStatus.pending,
    this.filePath,
    this.error,
    this.downloadedAt,
    this.fileSize,
    this.needsFreshLink = false,
    this.missingFile = false,
    this.quotaExceeded = false,
    this.magicMismatch = false,
    this.wifiOnlyBlocked = false,
    this.pinned = false,
    this.presetUrl,
    this.source,
    this.customSubfolder,
  });

  DownloadTask copyWith({
    String? id,
    Book? book,
    double? progress,
    DownloadStatus? status,
    String? filePath,
    String? error,
    DateTime? downloadedAt,
    int? fileSize,
    bool? needsFreshLink,
    bool? missingFile,
    bool? quotaExceeded,
    bool? magicMismatch,
    bool? wifiOnlyBlocked,
    bool? pinned,
    String? presetUrl,
    BookSource? source,
    String? customSubfolder,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      book: book ?? this.book,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      filePath: filePath ?? this.filePath,
      error: error ?? this.error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      fileSize: fileSize ?? this.fileSize,
      needsFreshLink: needsFreshLink ?? this.needsFreshLink,
      missingFile: missingFile ?? this.missingFile,
      quotaExceeded: quotaExceeded ?? this.quotaExceeded,
      magicMismatch: magicMismatch ?? this.magicMismatch,
      wifiOnlyBlocked: wifiOnlyBlocked ?? this.wifiOnlyBlocked,
      pinned: pinned ?? this.pinned,
      presetUrl: presetUrl ?? this.presetUrl,
      source: source ?? this.source,
      customSubfolder: customSubfolder ?? this.customSubfolder,
    );
  }
}

/// Z 站当日下载额度已用尽。精简版仓库里此前只有引用、没有定义
///（原定义随私有插件缺失），此处按仓库内同类异常的写法补定义；
/// 用法只有无参构造与类型捕获，不携带额外字段。
class DownloadLimitReachedException implements Exception {
  const DownloadLimitReachedException();
  @override
  String toString() => 'DownloadLimitReachedException';
}
