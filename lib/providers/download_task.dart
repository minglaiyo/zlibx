// Download task model, split out of download_provider.dart.
import 'package:olib_api_plugin/olib_api_plugin.dart';

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

  /// 仅 Wi-Fi 下载（方案 E1）：发起时网络是计费连接（移动数据/无网），
  /// 任务被拒绝启动。到 Wi-Fi 后重试即可。
  final bool wifiOnlyBlocked;

  /// 下载队列置顶（方案 E2）：pending 任务被用户置顶，排在其他等待
  /// 任务之前。瞬时意图（重启后队列重建，不持久化）。
  final bool pinned;

  /// 外部源直链（Anna/LibGen 解析出的 URL）。暂停后恢复要用同一个
  /// 入口重跑下载流程；z 站任务为 null。
  final String? presetUrl;

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
    this.wifiOnlyBlocked = false,
    this.pinned = false,
    this.presetUrl,
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
    bool? wifiOnlyBlocked,
    bool? pinned,
    String? presetUrl,
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
      wifiOnlyBlocked: wifiOnlyBlocked ?? this.wifiOnlyBlocked,
      pinned: pinned ?? this.pinned,
      presetUrl: presetUrl ?? this.presetUrl,
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
