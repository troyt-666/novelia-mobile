import '../../core/database/sqlite_offline_repository.dart';
import '../../core/database/local_state_repository.dart';
import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../../gateway/novelia/novelia_content_cache_adapter.dart';
import '../../gateway/novelia/novelia_domain_adapter.dart';
import '../discover/catalog_models.dart';
import 'shell_view_models.dart';

/// A shelf projection loaded on local-data changes, never during widget build.
class LocalLibrarySnapshot {
  LocalLibrarySnapshot.load(
    SqliteOfflineRepository repository, {
    required Iterable<CatalogNovel> knownNovels,
    required bool allowRestricted,
  }) {
    final progress = repository.listReadingProgress().toList();
    final savedBookmarks = repository.listBookmarks().toList();
    final intents = repository.listIntents();
    final copies = repository.listCopies(kind: OfflineCopyKind.offlineDownload);
    final tasks = repository.listTasks();
    final novelIds = {
      for (final row in progress) row.novelId,
      for (final row in savedBookmarks) row.novelId,
      for (final row in intents) row.novelId,
      for (final row in copies) row.novelId,
      for (final row in tasks)
        if (row.state != DownloadTaskState.removed) row.novelId,
    };
    const adapter = NoveliaContentCacheAdapter();
    final novels = <String, CatalogNovel>{};
    for (final id in novelIds) {
      try {
        final outline = repository.cachedNovelOutline(id);
        if (outline != null) {
          novels[id] = adapter.restoreOutline(
            outline,
            allowRestricted: allowRestricted,
          );
        }
        final detail = repository.novelDetail(id);
        if (detail != null) {
          novels[id] = adapter.restoreDetails(
            detail,
            allowRestricted: allowRestricted,
          );
        }
      } on Object {
        // One obsolete or corrupt title must not hide the rest of the shelf.
      }
    }
    for (final novel in knownNovels) {
      if (!novelIds.contains(novel.id)) continue;
      if (!allowRestricted &&
          const NoveliaDomainAdapter().isRestrictedCatalogNovel(novel)) {
        continue;
      }
      if (novels[novel.id] == null || novel.readerNovel != null) {
        novels[novel.id] = novel;
      }
    }
    continuedReads = _libraryContinuedReads(novels, progress, repository);
    downloads = _libraryDownloads(novels, intents, copies, tasks);
    bookmarks = _libraryBookmarks(novels, savedBookmarks);
    storageSummary = repository.storageSummary();
  }

  late final List<LibraryContinuedRead> continuedReads;
  late final List<LibraryProtectedDownload> downloads;
  late final List<LibraryBookmarkItem> bookmarks;
  late final OfflineStorageSummary storageSummary;

  static List<LibraryContinuedRead> _libraryContinuedReads(
    Map<String, CatalogNovel> novelsById,
    List<LocalReadingProgress> progress,
    SqliteOfflineRepository repository,
  ) {
    progress.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable([
      for (final item in progress)
        if (novelsById[item.novelId] case final novel?)
          LibraryContinuedRead(
            novel: novel,
            position: item.position,
            progress: _readingFraction(repository, novel, item.position),
            chapterLabel: _chapterLabel(novel, item.position.chapterId),
          ),
    ]);
  }

  static double _readingFraction(
    SqliteOfflineRepository repository,
    CatalogNovel novel,
    ReadingPosition position,
  ) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    final chapterIndex = chapters.indexWhere(
      (chapter) => chapter.id == position.chapterId,
    );
    if (chapterIndex < 0) return 0;
    final payload = repository.chapterPayload(
      novelId: novel.id,
      chapterId: position.chapterId,
    );
    final blockCount = payload?.japaneseBlocks.length ?? 0;
    final separator = position.blockId.lastIndexOf(':');
    final ordinal = separator < 0
        ? null
        : int.tryParse(position.blockId.substring(separator + 1));
    final chapterFraction = blockCount <= 0 || ordinal == null
        ? 0.0
        : ((ordinal + 1) / blockCount).clamp(0.0, 1.0);
    return ((chapterIndex + chapterFraction) / chapters.length).clamp(0.0, 1.0);
  }

  static String? _chapterLabel(CatalogNovel novel, String chapterId) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return null;
    for (final chapter in chapters) {
      if (chapter.id == chapterId) {
        return chapter.chineseTitle.isEmpty
            ? chapter.japaneseTitle
            : chapter.chineseTitle;
      }
    }
    return null;
  }

  static List<LibraryProtectedDownload> _libraryDownloads(
    Map<String, CatalogNovel> novelsById,
    List<DownloadIntent> intents,
    List<OfflineChapterCopy> copies,
    List<DownloadTask> tasks,
  ) {
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
      final chapterIds = {...copies.keys, ...tasks.keys}.toList()
        ..sort((a, b) {
          final aIndex = _chapterCatalogIndex(novel, a);
          final bIndex = _chapterCatalogIndex(novel, b);
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
  }) {
    final storedBytes = copy?.totalBytes;
    final state = _displayTaskState(copy, task);
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
      failure: task?.failure,
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

  static int _chapterCatalogIndex(CatalogNovel novel, String chapterId) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return 1 << 30;
    final index = chapters.indexWhere((chapter) => chapter.id == chapterId);
    return index < 0 ? 1 << 30 : index;
  }

  static List<LibraryBookmarkItem> _libraryBookmarks(
    Map<String, CatalogNovel> novelsById,
    List<LocalBookmark> bookmarks,
  ) {
    bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable([
      for (final bookmark in bookmarks)
        if (novelsById[bookmark.novelId] case final novel?)
          LibraryBookmarkItem(
            id: bookmark.id,
            novel: novel,
            position: bookmark.position,
            chapterLabel: _chapterLabel(novel, bookmark.position.chapterId),
          ),
    ]);
  }
}
