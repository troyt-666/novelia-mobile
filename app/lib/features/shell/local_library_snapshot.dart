import '../../core/database/sqlite_offline_repository.dart';
import '../../core/database/local_state_repository.dart';
import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../../gateway/novelia/novelia_content_cache_adapter.dart';
import '../discover/catalog_models.dart';
import 'shell_view_models.dart';

/// A shelf projection loaded on local-data changes, never during widget build.
/// Device-local reading data is independent of website login and catalog access.
class LocalLibrarySnapshot {
  LocalLibrarySnapshot.load(
    SqliteOfflineRepository repository, {
    required Iterable<CatalogNovel> knownNovels,
  }) {
    final progress = repository.listReadingProgress();
    final savedBookmarks = repository.listBookmarks();
    final intents = repository.listIntents();
    final copies = repository.listCopies();
    final downloadedCopies = copies.where(
      (copy) => copy.kind == OfflineCopyKind.offlineDownload,
    );
    final tasks = repository.listTasks();
    novelIds = {
      for (final row in progress) row.novelId,
      for (final row in savedBookmarks) row.novelId,
      for (final row in intents) row.novelId,
      for (final row in downloadedCopies) row.novelId,
      for (final row in tasks)
        if (row.state != DownloadTaskState.removed) row.novelId,
    };
    const adapter = NoveliaContentCacheAdapter();
    final novels = <String, CatalogNovel>{};
    for (final id in novelIds) {
      try {
        final outline = repository.cachedNovelOutline(id);
        if (outline != null) {
          novels[id] = adapter.restoreOutline(outline, allowRestricted: true);
        }
      } on Object {
        // One obsolete or corrupt title must not hide the rest of the shelf.
      }
    }
    for (final novel in knownNovels) {
      if (!novelIds.contains(novel.id)) continue;
      novels.putIfAbsent(novel.id, () => novel);
    }
    continuedReads = _libraryContinuedReads(novels, progress, repository);
    downloads = _libraryDownloads(
      novels,
      intents,
      downloadedCopies,
      tasks,
      progress,
      savedBookmarks,
      repository.payloadIdsMissingIllustrations(),
      repository,
    );
    bookmarks = _libraryBookmarks(novels, savedBookmarks, repository);
    storageSummary = OfflineStorageSummary.fromCopies(copies);
  }

  late final List<LibraryContinuedRead> continuedReads;
  late final Set<String> novelIds;
  late final List<LibraryProtectedDownload> downloads;
  late final List<LibraryBookmarkItem> bookmarks;
  late final OfflineStorageSummary storageSummary;

  static List<LibraryContinuedRead> _libraryContinuedReads(
    Map<String, CatalogNovel> novelsById,
    List<LocalReadingProgress> progress,
    SqliteOfflineRepository repository,
  ) {
    final result = <LibraryContinuedRead>[];
    for (final item in progress) {
      final novel = novelsById[item.novelId];
      if (novel == null) continue;
      final location = _chapterLocation(
        repository,
        novel,
        item.position.chapterId,
      );
      result.add(
        LibraryContinuedRead(
          novel: novel,
          position: item.position,
          progress: _readingFraction(
            repository,
            novel.id,
            location,
            item.position,
          ),
          chapterLabel: location?.title,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  static double _readingFraction(
    SqliteOfflineRepository repository,
    String novelId,
    LocalChapterLocation? location,
    ReadingPosition position,
  ) {
    if (location == null || location.chapterCount == 0) return 0;
    final blockCount = repository.chapterBlockCount(
      novelId,
      position.chapterId,
    );
    final separator = position.blockId.lastIndexOf(':');
    final ordinal = separator < 0
        ? null
        : int.tryParse(position.blockId.substring(separator + 1));
    final chapterFraction = blockCount <= 0 || ordinal == null
        ? 0.0
        : ((ordinal + 1) / blockCount).clamp(0.0, 1.0);
    return ((location.ordinal + chapterFraction) / location.chapterCount).clamp(
      0.0,
      1.0,
    );
  }

  static LocalChapterLocation? _chapterLocation(
    SqliteOfflineRepository repository,
    CatalogNovel novel,
    String chapterId,
  ) {
    final saved = repository.chapterLocation(novel.id, chapterId);
    if (saved != null) return saved;
    // In-memory catalog entries may not have reached the persistent cache yet.
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return null;
    for (var index = 0; index < chapters.length; index++) {
      final chapter = chapters[index];
      if (chapter.id == chapterId) {
        return LocalChapterLocation(
          title: chapter.chineseTitle.isEmpty
              ? chapter.japaneseTitle
              : chapter.chineseTitle,
          ordinal: index,
          chapterCount: chapters.length,
        );
      }
    }
    return null;
  }

  static List<LibraryProtectedDownload> _libraryDownloads(
    Map<String, CatalogNovel> novelsById,
    List<DownloadIntent> intents,
    Iterable<OfflineChapterCopy> copies,
    List<DownloadTask> tasks,
    List<LocalReadingProgress> progress,
    List<LocalBookmark> bookmarks,
    Set<String> missingIllustrationPayloads,
    SqliteOfflineRepository repository,
  ) {
    final lastActivity = <String, DateTime>{};
    for (final (novelId, time) in [
      for (final intent in intents) (intent.novelId, intent.createdAt),
      for (final copy in copies) (copy.novelId, copy.storedAt),
      for (final copy in copies) (copy.novelId, copy.lastReadAt),
      for (final task in tasks)
        if (task.state != DownloadTaskState.removed)
          (task.novelId, task.updatedAt),
      for (final item in progress) (item.novelId, item.updatedAt),
      for (final bookmark in bookmarks) (bookmark.novelId, bookmark.createdAt),
    ]) {
      final previous = lastActivity[novelId];
      if (previous == null || time.isAfter(previous)) {
        lastActivity[novelId] = time;
      }
    }
    final intentsByGroup =
        <(String, TranslationSource), List<DownloadIntent>>{};
    for (final intent in intents) {
      final group = (intent.novelId, intent.translationSource);
      intentsByGroup.putIfAbsent(group, () => []).add(intent);
    }

    final copiesByGroup =
        <(String, TranslationSource), Map<String, OfflineChapterCopy>>{};
    for (final copy in copies) {
      final group = (copy.novelId, copy.translationSource);
      final copies = copiesByGroup.putIfAbsent(group, () => {});
      final existing = copies[copy.chapterId];
      if (existing == null || copy.storedAt.isAfter(existing.storedAt)) {
        copies[copy.chapterId] = copy;
      }
    }

    final tasksByGroup =
        <(String, TranslationSource), Map<String, DownloadTask>>{};
    for (final task in tasks) {
      if (task.state == DownloadTaskState.removed) continue;
      final group = (task.novelId, task.translationSource);
      final tasks = tasksByGroup.putIfAbsent(group, () => {});
      final existing = tasks[task.chapterId];
      if (existing == null || task.updatedAt.isAfter(existing.updatedAt)) {
        tasks[task.chapterId] = task;
      }
    }

    final groups =
        {
          ...intentsByGroup.keys,
          ...copiesByGroup.keys,
          ...tasksByGroup.keys,
        }.toList()..sort((a, b) {
          final activityOrder = lastActivity[b.$1]!.compareTo(
            lastActivity[a.$1]!,
          );
          if (activityOrder != 0) return activityOrder;
          final novelOrder = a.$1.compareTo(b.$1);
          return novelOrder == 0
              ? a.$2.index.compareTo(b.$2.index)
              : novelOrder;
        });
    final downloads = <LibraryProtectedDownload>[];
    for (final group in groups) {
      final novel = novelsById[group.$1];
      if (novel == null) continue;
      final intents = intentsByGroup[group] ?? const [];
      final copies = copiesByGroup[group] ?? const {};
      final tasks = tasksByGroup[group] ?? const {};
      final chapterIds = {...copies.keys, ...tasks.keys}.toList();
      final catalog = novel.readerNovel?.chapters ?? const [];
      final chapterOrder = catalog.isEmpty
          ? repository.chapterOrder(novel.id, chapterIds)
          : {
              for (var index = 0; index < catalog.length; index++)
                catalog[index].id: index,
            };
      chapterIds.sort((a, b) {
        final aIndex = chapterOrder[a] ?? 1 << 30;
        final bIndex = chapterOrder[b] ?? 1 << 30;
        final order = aIndex.compareTo(bIndex);
        return order == 0 ? a.compareTo(b) : order;
      });
      downloads.add(
        LibraryProtectedDownload(
          novel: novel,
          translationSource: group.$2,
          intentIds: [for (final intent in intents) intent.id],
          enabled: intents.any((intent) => intent.enabled),
          chapters: [
            for (final chapterId in chapterIds)
              _libraryDownloadChapter(
                chapterId,
                copy: copies[chapterId],
                task: tasks[chapterId],
                imagesMissing: missingIllustrationPayloads.contains(
                  copies[chapterId]?.payloadId,
                ),
              ),
          ],
        ),
      );
    }
    return List.unmodifiable(downloads);
  }

  static LibraryDownloadChapter _libraryDownloadChapter(
    String chapterId, {
    required OfflineChapterCopy? copy,
    required DownloadTask? task,
    required bool imagesMissing,
  }) {
    final storedBytes = copy?.totalBytes;
    final state = imagesMissing
        ? DownloadTaskState.failed
        : _displayTaskState(copy, task);
    return LibraryDownloadChapter(
      chapterId: chapterId,
      byteCount: storedBytes ?? 0,
      translationAvailable: copy?.translationBytes != null,
      taskState: state,
      bytesReceived: state == DownloadTaskState.stored
          ? storedBytes ?? task?.bytesReceived ?? 0
          : task?.bytesReceived ?? 0,
      totalBytes: state == DownloadTaskState.stored
          ? storedBytes ?? task?.totalBytes
          : task?.totalBytes,
      failure: imagesMissing
          ? const DownloadFailure(
              kind: DownloadFailureKind.illustration,
              message: '插图尚未下载完整，请联网后重试。',
              retryable: true,
            )
          : task?.failure,
    );
  }

  static DownloadTaskState _displayTaskState(
    OfflineChapterCopy? copy,
    DownloadTask? task,
  ) {
    if (copy != null &&
        (task == null ||
            task.state == DownloadTaskState.stored ||
            task.storedCopyId != copy.id)) {
      return DownloadTaskState.stored;
    }
    return task?.state ?? DownloadTaskState.stored;
  }

  static List<LibraryBookmarkItem> _libraryBookmarks(
    Map<String, CatalogNovel> novelsById,
    List<LocalBookmark> bookmarks,
    SqliteOfflineRepository repository,
  ) {
    return List.unmodifiable([
      for (final bookmark in bookmarks)
        if (novelsById[bookmark.novelId] case final novel?)
          LibraryBookmarkItem(
            id: bookmark.id,
            novel: novel,
            position: bookmark.position,
            chapterLabel: _chapterLocation(
              repository,
              novel,
              bookmark.position.chapterId,
            )?.title,
          ),
    ]);
  }
}
