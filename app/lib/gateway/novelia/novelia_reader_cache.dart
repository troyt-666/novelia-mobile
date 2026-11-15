import 'dart:isolate';

import '../../core/database/sqlite_offline_repository.dart';
import '../../core/model/reader_models.dart';
import 'novelia_content_cache_adapter.dart';

class NoveliaReaderCacheResult {
  const NoveliaReaderCacheResult(this.chapter, {this.downloaded = false});
  final NovelChapter? chapter;
  final bool downloaded;
}

typedef NoveliaReaderCacheLoader =
    Future<NoveliaReaderCacheResult> Function(
      String novelId,
      String chapterId,
      TranslationSource source,
    );

/// Decode JSON/images, verify checksums and construct blocks off the UI isolate.
/// Each read uses one consistent, read-only view of the local database.
class BackgroundReaderCache {
  static Future<NoveliaReaderCacheResult> load(
    String databasePath,
    String novelId,
    String chapterId,
    TranslationSource source,
  ) => Isolate.run(() {
    final repository = SqliteOfflineRepository.openReadSnapshot(databasePath);
    try {
      const adapter = NoveliaContentCacheAdapter();
      final downloaded = repository.downloadedChapterPayload(
        novelId: novelId,
        chapterId: chapterId,
        translationSource: source,
      );
      if (downloaded != null) {
        return NoveliaReaderCacheResult(
          adapter.restoreChapter(downloaded),
          downloaded: true,
        );
      }
      try {
        final cached = repository.chapterPayload(
          novelId: novelId,
          chapterId: chapterId,
        );
        return NoveliaReaderCacheResult(
          cached == null ? null : adapter.restoreChapter(cached),
        );
      } on Object {
        // An expendable corrupt cache is a miss; protected downloads above
        // retain their explicit failure instead of silently changing revisions.
        return const NoveliaReaderCacheResult(null);
      }
    } finally {
      repository.close();
    }
  });
}
