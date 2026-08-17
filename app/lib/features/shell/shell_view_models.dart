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
  }) {
    if (chapterId.isEmpty) throw ArgumentError.value(chapterId, 'chapterId');
    if (byteCount < 0) throw ArgumentError.value(byteCount, 'byteCount');
  }

  final String chapterId;
  final int byteCount;
  final bool translationAvailable;
  final DownloadTaskState taskState;
}

class LibraryProtectedDownload {
  LibraryProtectedDownload({
    required this.novel,
    required this.translationSource,
    required List<LibraryDownloadChapter> chapters,
  }) : chapters = List.unmodifiable(chapters) {
    final ids = <String>{};
    for (final chapter in chapters) {
      if (!ids.add(chapter.chapterId)) {
        throw ArgumentError('Download repeats chapter ${chapter.chapterId}.');
      }
    }
  }

  final CatalogNovel novel;
  final TranslationSource translationSource;
  final List<LibraryDownloadChapter> chapters;

  int get totalBytes => chapters.fold(0, (sum, item) => sum + item.byteCount);

  int countWithState(DownloadTaskState state) {
    return chapters.where((chapter) => chapter.taskState == state).length;
  }

  int get translationPendingCount {
    return chapters.where((chapter) => !chapter.translationAvailable).length;
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
    required this.novelCount,
  });

  final String id;
  final String title;
  final int novelCount;
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
