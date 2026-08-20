import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../discover/catalog_models.dart';

class LibraryContinuedRead {
  LibraryContinuedRead({
    required this.novel,
    required this.position,
    required this.progress,
    this.chapterLabel,
  }) {
    if (progress < 0 || progress > 1) {
      throw ArgumentError.value(progress, 'progress');
    }
  }

  final CatalogNovel novel;
  final ReadingPosition position;
  final double progress;
  final String? chapterLabel;
}

class LibraryDownloadChapter {
  LibraryDownloadChapter({
    required this.chapterId,
    required this.byteCount,
    required this.translationAvailable,
    required this.taskState,
    this.bytesReceived = 0,
    this.totalBytes,
    this.failure,
  }) {
    if (chapterId.isEmpty) throw ArgumentError.value(chapterId, 'chapterId');
    if (byteCount < 0) throw ArgumentError.value(byteCount, 'byteCount');
    if (bytesReceived < 0 ||
        (totalBytes != null &&
            (totalBytes! < 0 || bytesReceived > totalBytes!))) {
      throw ArgumentError('Download byte progress is inconsistent.');
    }
  }

  final String chapterId;
  final int byteCount;
  final bool translationAvailable;
  final DownloadTaskState taskState;
  final int bytesReceived;
  final int? totalBytes;
  final DownloadFailure? failure;

  double? get byteProgressFraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (bytesReceived / total).clamp(0.0, 1.0);
  }
}

class LibraryProtectedDownload {
  LibraryProtectedDownload({
    required this.novel,
    required this.translationSource,
    required List<LibraryDownloadChapter> chapters,
    List<String> intentIds = const [],
    this.enabled = true,
  }) : chapters = List.unmodifiable(chapters),
       intentIds = List.unmodifiable(intentIds) {
    final ids = <String>{};
    for (final chapter in chapters) {
      if (!ids.add(chapter.chapterId)) {
        throw ArgumentError('Download repeats chapter ${chapter.chapterId}.');
      }
    }
    if (intentIds.any((id) => id.isEmpty) ||
        intentIds.toSet().length != intentIds.length) {
      throw ArgumentError('Download intent IDs must be non-empty and unique.');
    }
  }

  final CatalogNovel novel;
  final TranslationSource translationSource;
  final List<LibraryDownloadChapter> chapters;
  final List<String> intentIds;
  final bool enabled;

  String get groupKey => '${novel.id}::${translationSource.name}';

  int get totalBytes => chapters.fold(0, (sum, item) => sum + item.byteCount);

  int countWithState(DownloadTaskState state) {
    return chapters.where((chapter) => chapter.taskState == state).length;
  }

  int get translationPendingCount {
    return chapters.where((chapter) => !chapter.translationAvailable).length;
  }

  int get retryableFailureCount => chapters
      .where(
        (chapter) =>
            chapter.taskState == DownloadTaskState.failed &&
            chapter.failure?.retryable == true,
      )
      .length;

  int get permanentFailureCount => chapters
      .where(
        (chapter) =>
            chapter.taskState == DownloadTaskState.failed &&
            chapter.failure?.retryable != true,
      )
      .length;

  int get completedChapterCount => countWithState(DownloadTaskState.stored);

  bool get isComplete =>
      chapters.isNotEmpty && completedChapterCount == chapters.length;

  int get activeChapterCount => chapters
      .where(
        (chapter) => const {
          DownloadTaskState.fetching,
          DownloadTaskState.validating,
          DownloadTaskState.storing,
        }.contains(chapter.taskState),
      )
      .length;

  /// Chapter completion is always available once the TOC has been reconciled.
  /// A known byte fraction contributes partial credit for the active chapter.
  double? get progressFraction {
    if (chapters.isEmpty) return null;
    var completed = 0.0;
    for (final chapter in chapters) {
      if (chapter.taskState == DownloadTaskState.stored) {
        completed += 1;
      } else if (chapter.taskState == DownloadTaskState.fetching) {
        completed += chapter.byteProgressFraction ?? 0;
      }
    }
    return (completed / chapters.length).clamp(0.0, 1.0);
  }
}

class LibraryBookmarkItem {
  const LibraryBookmarkItem({
    required this.id,
    required this.novel,
    required this.position,
    this.chapterLabel,
  });

  final String id;
  final CatalogNovel novel;
  final ReadingPosition position;
  final String? chapterLabel;
}

class LibraryFavoriteFolder {
  const LibraryFavoriteFolder({
    required this.id,
    required this.title,
    this.novelCount,
  });

  final String id;
  final String title;

  /// Null when the folder-list response does not provide a count.
  final int? novelCount;
}

enum RemoteFavoritesStatus { unavailable, empty, available }

class RemoteFavoritesViewModel {
  const RemoteFavoritesViewModel.unavailable()
    : status = RemoteFavoritesStatus.unavailable,
      folders = const [];

  const RemoteFavoritesViewModel.empty()
    : status = RemoteFavoritesStatus.empty,
      folders = const [];

  RemoteFavoritesViewModel.available(List<LibraryFavoriteFolder> folders)
    : status = RemoteFavoritesStatus.available,
      folders = List.unmodifiable(folders) {
    if (folders.isEmpty) {
      throw ArgumentError('Use RemoteFavoritesViewModel.empty for no folders.');
    }
  }

  final RemoteFavoritesStatus status;
  final List<LibraryFavoriteFolder> folders;
}

String formatStorageBytes(int bytes) {
  if (bytes < 0) throw ArgumentError.value(bytes, 'bytes');
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unitIndex]}';
}

String libraryDownloadSummary(LibraryProtectedDownload download) {
  final status = <String>[];
  if (!download.isComplete) {
    final failed = download.countWithState(DownloadTaskState.failed);
    final paused = download.countWithState(DownloadTaskState.paused);
    final active = download.chapters.where((chapter) {
      return const {
        DownloadTaskState.queued,
        DownloadTaskState.fetching,
        DownloadTaskState.validating,
        DownloadTaskState.storing,
      }.contains(chapter.taskState);
    }).length;
    if (failed > 0) status.add('$failed 章失败');
    if (paused > 0 || !download.enabled) status.add('已暂停');
    if (active > 0) status.add('$active 章下载中');
  }
  if (download.translationPendingCount > 0) {
    status.add('${download.translationPendingCount} 章待翻译');
  }
  if (status.isEmpty) status.add('已存储');
  return '${download.chapters.length} 章 · '
      '${download.translationSource.label} · '
      '${formatStorageBytes(download.totalBytes)} · ${status.join(' · ')}';
}
