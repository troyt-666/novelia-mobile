import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';

final backupTime = DateTime.utc(2026, 9, 15, 8);
const backupNovelId = 'syosetu/n1000bk';

void seedBackupNovel(
  SqliteOfflineRepository repo, {
  String id = backupNovelId,
  String title = '在旧书店等一场雨',
}) {
  repo.upsertNovelDetail(
    CachedNovelDetail(
      outline: CachedNovelOutline(
        id: id,
        chineseTitle: title,
        japaneseTitle: '',
        author: '测试作者',
        contentSource: '小説家になろう',
        publicationState: CachedNovelState.ongoing,
        chapterCount: 3,
        wordCount: null,
        updatedAt: backupTime,
        tags: [],
        translationCoverage: [],
        fetchedAt: backupTime,
      ),
      synopsis: '用于备份测试的虚构小说。',
      points: null,
      views: null,
      originalUrl: null,
      sections: [
        CachedTocSection(
          id: '$id:section:0',
          title: '目录',
          chapters: [
            for (var i = 1; i <= 3; i++)
              CachedTocChapter(
                id: 'c$i',
                index: i - 1,
                chineseTitle: '第 $i 章 ${['雨中的书店', '夏日来信', '最后一班电车'][i - 1]}',
                japaneseTitle: '',
              ),
          ],
        ),
      ],
    ),
  );
}

void seedBackupProgress(
  SqliteOfflineRepository repo, {
  String id = backupNovelId,
  String chapter = 'c2',
  int paragraph = 8,
  DateTime? time,
}) {
  repo.saveReadingProgress(
    LocalReadingProgress(
      novelId: id,
      position: ReadingPosition(
        chapterId: chapter,
        blockId: '$chapter:$paragraph',
        intraBlockOffset: 12,
      ),
      updatedAt: time ?? backupTime,
    ),
  );
}

void seedBackupBookmark(
  SqliteOfflineRepository repo, {
  String bookmarkId = 'bookmark',
  String novelId = backupNovelId,
  String chapter = 'c1',
  int paragraph = 2,
}) {
  repo.saveBookmark(
    LocalBookmark(
      id: bookmarkId,
      novelId: novelId,
      position: ReadingPosition(
        chapterId: chapter,
        blockId: '$chapter:$paragraph',
      ),
      createdAt: backupTime,
    ),
  );
}

void seedBackupDownload(
  SqliteOfflineRepository repo, {
  String novelId = backupNovelId,
  String chapter = 'c1',
  String intentId = 'intent',
  String payloadId = 'payload',
  String copyId = 'copy',
  TranslationSource source = TranslationSource.sakura,
  String text = '测试译文',
  bool cacheOnly = false,
}) {
  final payload = CachedChapterPayload(
    id: payloadId,
    novelId: novelId,
    chapterId: chapter,
    index: 0,
    chineseTitle: '测试章节',
    japaneseTitle: '',
    previousChapterId: null,
    nextChapterId: null,
    publishedAt: null,
    japaneseBlocks: ['原文'],
    translations: {
      source: CachedChapterTranslation(
        availability: TranslationAvailability.complete,
        blocks: [text],
      ),
    },
    fetchedAt: backupTime,
    revision: 'r1',
  );
  final copy = OfflineChapterCopy(
    id: copyId,
    novelId: novelId,
    chapterId: chapter,
    kind: cacheOnly
        ? OfflineCopyKind.cacheCopy
        : OfflineCopyKind.offlineDownload,
    translationSource: source,
    originalBytes: 6,
    translationBytes: text.length * 3,
    storedAt: backupTime,
    intentId: cacheOnly ? null : intentId,
    payloadId: payloadId,
    revision: 'r1',
  );
  if (cacheOnly) {
    repo.cacheChapterPayload(payload: payload, copy: copy);
    return;
  }
  repo.saveIntent(
    NovelDownloadIntent(
      id: intentId,
      novelId: novelId,
      translationSource: source,
      createdAt: backupTime,
    ),
  );
  var task = repo
      .reconcileIntent(
        intentId: intentId,
        knownChapterIds: [chapter],
        now: backupTime,
      )
      .single;
  task = task.beginFetching(backupTime);
  repo.saveTask(task);
  task = task.beginValidation(backupTime);
  repo.saveTask(task);
  task = task.beginStoring(backupTime);
  repo.saveTask(task);
  repo.commitDownloadedChapter(
    taskId: task.id,
    payload: payload,
    copy: copy,
    now: backupTime,
  );
}
