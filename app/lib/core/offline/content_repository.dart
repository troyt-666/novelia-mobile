import 'content_models.dart';
import 'offline_models.dart';

/// Local normalized content store, independent of gateway DTOs and UI models.
abstract interface class ContentRepository {
  List<CachedNovelOutline> listCachedNovels();

  CachedNovelDetail? novelDetail(String novelId);

  CachedChapterPayload? chapterPayload({
    required String novelId,
    required String chapterId,
  });

  /// Resolves the exact revision referenced by an Offline Chapter Copy.
  CachedChapterPayload? chapterPayloadById(String payloadId);

  void upsertNovelOutline(CachedNovelOutline outline);

  void upsertNovelDetail(CachedNovelDetail detail);

  /// Atomically writes an expendable fetched payload and its Cache Copy.
  void cacheChapterPayload({
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  });

  /// Atomically writes a real payload, its protected copy, and task completion.
  OfflineChapterCopy commitDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
    required DateTime now,
  });

  /// Atomically repoints an existing protected download to a fresher payload
  /// without changing its already-stored Download Task.
  OfflineChapterCopy refreshDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  });

  /// Removes expendable cached content for one novel.
  ///
  /// Existing outline/detail/TOC metadata remains while a download intent or
  /// protected copy still needs it for offline discovery and reader launch.
  void removeCachedNovel(String novelId);
}
