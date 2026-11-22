// Downloads-tab list structure, split out of download_provider.dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'download_provider.dart';


/// Task ids per downloads tab, in display order, with value equality:
/// two structures are equal when both id lists match element-wise and
/// every completed id's download stamp matches. Progress ticks change
/// neither list nor stamp, so a screen watching this rebuilds only
/// when a task is added/removed, changes status (and so moves tabs),
/// or completes (changing the completed order).
class DownloadListStructure {
  const DownloadListStructure({
    required this.ongoingIds,
    required this.completedIds,
    required this.completedDates,
  });

  final List<String> ongoingIds;
  final List<String> completedIds;

  /// Download stamp per completed id (null = no stamp recorded):
  /// the screen groups the completed tab by date from this map
  /// instead of watching each task (which would rebuild the screen
  /// on every progress tick).
  final Map<String, DateTime?> completedDates;

  @override
  bool operator ==(Object other) =>
      other is DownloadListStructure &&
      _idsEqual(ongoingIds, other.ongoingIds) &&
      _idsEqual(completedIds, other.completedIds) &&
      _datesEqual(completedDates, other.completedDates);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(ongoingIds),
    Object.hashAll(completedIds),
    // Sort by key first: Map iteration order is insertion order, and
    // two equal maps built in different orders must hash the same.
    Object.hashAll(
      (completedDates.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

bool _datesEqual(Map<String, DateTime?> a, Map<String, DateTime?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

bool _idsEqual(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Display order within the downloads tabs (same sort the screen used
/// to do inline: ongoing by status priority, completed newest first).
int _downloadPriority(DownloadStatus status) => switch (status) {
  DownloadStatus.downloading => 0,
  DownloadStatus.pending => 1,
  DownloadStatus.paused => 1,
  DownloadStatus.error => 2,
  DownloadStatus.cancelled => 3,
  DownloadStatus.completed => 4,
};

/// The downloads list structure (ids per tab, in display order).
/// Watch this in the list screen instead of [downloadProvider]: the
/// structure only changes when the set of tasks or their statuses
/// change, so progress ticks do not rebuild the screen. Each row then
/// watches [downloadTaskProvider] for its own live task.
final downloadListStructureProvider = Provider<DownloadListStructure>((ref) {
  return ref.watch(
    downloadProvider.select((tasks) {
      final ongoing =
          tasks
              .where((task) => task.status != DownloadStatus.completed)
              .toList()
            ..sort(
              (a, b) {
                final byPriority = _downloadPriority(
                  a.status,
                ).compareTo(_downloadPriority(b.status));
                if (byPriority != 0) return byPriority;
                // 同优先级里置顶（E2）的 pending 排最前；Dart 的 sort
                // 不稳定，必须有显式平局规则。
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                return 0;
              },
            );
      final completed =
          tasks
              .where((task) => task.status == DownloadStatus.completed)
              .toList()
            ..sort(
              (a, b) => (b.downloadedAt ?? DateTime(0)).compareTo(
                a.downloadedAt ?? DateTime(0),
              ),
            );
      return DownloadListStructure(
        ongoingIds: ongoing.map((task) => task.id).toList(),
        completedIds: completed.map((task) => task.id).toList(),
        completedDates: {
          for (final task in completed) task.id: task.downloadedAt,
        },
      );
    }),
  );
});
