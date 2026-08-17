import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/core/offline/offline_models.dart';
import 'package:novelia_reader/core/offline/offline_repository.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 17, 1);

  group('offline copy semantics', () {
    test('Cache Copy is evictable while Offline Download is protected', () {
      final cache = cacheCopy(id: 'cache-c1', chapterId: 'c1', storedAt: t0);
      final download = downloadedCopy(
        id: 'download-c1',
        chapterId: 'c1',
        storedAt: t0,
      );

      expect(cache.isEvictable, isTrue);
      expect(cache.isProtected, isFalse);
      expect(download.isProtected, isTrue);
      expect(download.isEvictable, isFalse);
    });

    test('pending translation retains original and requested source', () {
      final copy = downloadedCopy(
        id: 'pending',
        chapterId: 'c2',
        storedAt: t0,
        translationBytes: null,
        source: TranslationSource.gpt,
      );

      expect(copy.originalBytes, 100);
      expect(copy.translationSource, TranslationSource.gpt);
      expect(copy.hasTranslation, isFalse);
      expect(copy.totalBytes, 100);
    });
  });

  group('download intent', () {
    test(
      'chapter intent remains fixed while novel intent tracks future IDs',
      () {
        final chapter = ChapterDownloadIntent(
          id: 'chapter-intent',
          novelId: 'novel',
          chapterId: 'c2',
          translationSource: TranslationSource.sakura,
          createdAt: t0,
        );
        final novel = NovelDownloadIntent(
          id: 'novel-intent',
          novelId: 'novel',
          translationSource: TranslationSource.sakura,
          createdAt: t0,
        );

        expect(chapter.tracksFutureChapters, isFalse);
        expect(chapter.targetChapterIds(['c1', 'c2', 'c3']), ['c2']);
        expect(novel.tracksFutureChapters, isTrue);
        expect(novel.targetChapterIds(['c1', 'c2', 'c2']), ['c1', 'c2']);
        expect(novel.targetChapterIds(['c1', 'c2', 'c3']), contains('c3'));
      },
    );

    test('disabled ongoing intent queues no chapters', () {
      final intent = NovelDownloadIntent(
        id: 'novel-intent',
        novelId: 'novel',
        translationSource: TranslationSource.youdao,
        createdAt: t0,
        enabled: false,
      );

      expect(intent.targetChapterIds(['c1']), isEmpty);
    });
  });

  group('download task state machine', () {
    test('runs queue, fetch, validate, store, and completion in order', () {
      var task = queuedTask(t0);
      task = task.beginFetching(
        t0.add(const Duration(seconds: 1)),
        expectedBytes: 200,
      );
      task = task.reportFetchProgress(
        t0.add(const Duration(seconds: 2)),
        bytesReceived: 200,
      );
      task = task.beginValidation(t0.add(const Duration(seconds: 3)));
      task = task.beginStoring(t0.add(const Duration(seconds: 4)));
      task = task.markStored(
        t0.add(const Duration(seconds: 5)),
        copyId: 'copy',
      );

      expect(task.state, DownloadTaskState.stored);
      expect(task.attemptCount, 1);
      expect(task.progressFraction, 1);
      expect(task.storedCopyId, 'copy');
      expect(task.revision, 5);
    });

    test('pause and resume preserve resumable byte progress', () {
      var task = queuedTask(t0)
          .beginFetching(t0.add(const Duration(seconds: 1)), expectedBytes: 200)
          .reportFetchProgress(
            t0.add(const Duration(seconds: 2)),
            bytesReceived: 80,
          )
          .pause(t0.add(const Duration(seconds: 3)));

      expect(task.state, DownloadTaskState.paused);
      task = task.resume(t0.add(const Duration(seconds: 4)));
      expect(task.state, DownloadTaskState.queued);
      expect(task.bytesReceived, 80);
      expect(task.totalBytes, 200);
    });

    test('only retryable failures return to queue', () {
      final fetching = queuedTask(
        t0,
      ).beginFetching(t0.add(const Duration(seconds: 1)));
      final retryable = fetching.fail(
        t0.add(const Duration(seconds: 2)),
        const DownloadFailure(
          kind: DownloadFailureKind.network,
          message: 'offline',
          retryable: true,
        ),
      );
      expect(
        retryable.retry(t0.add(const Duration(seconds: 3))).state,
        DownloadTaskState.queued,
      );

      final permanent = fetching.fail(
        t0.add(const Duration(seconds: 2)),
        const DownloadFailure(
          kind: DownloadFailureKind.validation,
          message: 'invalid alignment',
          retryable: false,
        ),
      );
      expect(
        () => permanent.retry(t0.add(const Duration(seconds: 3))),
        throwsStateError,
      );
    });

    test('rejects out-of-order transitions and stale progress', () {
      final queued = queuedTask(t0);
      expect(
        () => queued.beginValidation(t0.add(const Duration(seconds: 1))),
        throwsStateError,
      );
      final fetching = queued.beginFetching(
        t0.add(const Duration(seconds: 1)),
        expectedBytes: 100,
      );
      expect(
        () => fetching.reportFetchProgress(
          t0.add(const Duration(seconds: 2)),
          bytesReceived: 101,
        ),
        throwsArgumentError,
      );
    });
  });

  group('in-memory repository', () {
    test(
      'reconciliation deduplicates chapters and later queues the future',
      () {
        final repository = InMemoryOfflineRepository();
        repository.saveIntent(novelIntent(t0));

        expect(
          repository.reconcileIntent(
            intentId: 'intent',
            knownChapterIds: ['c1', 'c2'],
            now: t0,
          ),
          hasLength(2),
        );
        expect(
          repository.reconcileIntent(
            intentId: 'intent',
            knownChapterIds: ['c1', 'c2'],
            now: t0,
          ),
          isEmpty,
        );
        final future = repository.reconcileIntent(
          intentId: 'intent',
          knownChapterIds: ['c1', 'c2', 'c3'],
          now: t0.add(const Duration(days: 1)),
        );

        expect(future.single.chapterId, 'c3');
        expect(future.single.translationSource, TranslationSource.sakura);
      },
    );

    test('pause disables reconciliation and resume requeues paused work', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      repository.reconcileIntent(
        intentId: 'intent',
        knownChapterIds: ['c1'],
        now: t0,
      );

      repository.pauseIntent('intent', t0.add(const Duration(seconds: 1)));
      expect(repository.intentById('intent')!.enabled, isFalse);
      expect(repository.listTasks().single.state, DownloadTaskState.paused);
      expect(
        repository.reconcileIntent(
          intentId: 'intent',
          knownChapterIds: ['c1', 'c2'],
          now: t0.add(const Duration(seconds: 2)),
        ),
        isEmpty,
      );

      repository.resumeIntent('intent', t0.add(const Duration(seconds: 3)));
      expect(repository.intentById('intent')!.enabled, isTrue);
      expect(repository.listTasks().single.state, DownloadTaskState.queued);
    });

    test('atomically commits a matching validated copy', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      var task = repository
          .reconcileIntent(intentId: 'intent', knownChapterIds: ['c1'], now: t0)
          .single;
      task = task.beginFetching(t0.add(const Duration(seconds: 1)));
      repository.saveTask(task);
      task = task.beginValidation(t0.add(const Duration(seconds: 2)));
      repository.saveTask(task);
      task = task.beginStoring(t0.add(const Duration(seconds: 3)));
      repository.saveTask(task);
      final copy = downloadedCopy(
        id: 'download-c1',
        chapterId: 'c1',
        storedAt: t0.add(const Duration(seconds: 4)),
      );

      repository.commitStoredTask(
        taskId: task.id,
        copy: copy,
        now: t0.add(const Duration(seconds: 4)),
      );

      expect(repository.copyById(copy.id), same(copy));
      expect(repository.taskById(task.id)!.state, DownloadTaskState.stored);
    });

    test('rejects stale task writers', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      final task = repository
          .reconcileIntent(intentId: 'intent', knownChapterIds: ['c1'], now: t0)
          .single;
      repository.saveTask(
        task.beginFetching(t0.add(const Duration(seconds: 1))),
      );

      expect(
        () => repository.saveTask(
          task.beginFetching(t0.add(const Duration(seconds: 2))),
        ),
        throwsStateError,
      );
    });

    test('LRU eviction affects Cache Copies only and honors protection', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      repository.saveCopy(cacheCopy(id: 'old', chapterId: 'c1', storedAt: t0));
      repository.saveCopy(
        cacheCopy(
          id: 'protected',
          chapterId: 'c2',
          storedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      repository.saveCopy(
        downloadedCopy(id: 'download', chapterId: 'c3', storedAt: t0),
      );

      final evicted = repository.evictCacheTo(
        maxBytes: 150,
        protectedChapters: {
          const ChapterRef(novelId: 'novel', chapterId: 'c2'),
        },
      );

      expect(evicted.map((copy) => copy.id), ['old']);
      expect(repository.copyById('protected'), isNotNull);
      expect(repository.copyById('download'), isNotNull);
    });

    test('storage and progress summaries keep retention classes separate', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      repository.saveCopy(
        cacheCopy(id: 'cache', chapterId: 'c1', storedAt: t0),
      );
      repository.saveCopy(
        downloadedCopy(
          id: 'download',
          chapterId: 'c2',
          storedAt: t0,
          translationBytes: 120,
        ),
      );
      final tasks = repository.reconcileIntent(
        intentId: 'intent',
        knownChapterIds: ['c1', 'c2'],
        now: t0,
      );
      final fetching = tasks.first.beginFetching(t0, expectedBytes: 200);
      repository.saveTask(fetching);
      repository.saveTask(fetching.reportFetchProgress(t0, bytesReceived: 50));

      final storage = repository.storageSummary();
      final progress = repository.progressSummary(intentId: 'intent');

      expect(storage.cacheBytes, 150);
      expect(storage.offlineDownloadBytes, 220);
      expect(storage.cacheChapterCount, 1);
      expect(storage.offlineDownloadChapterCount, 1);
      expect(progress.totalTasks, 2);
      expect(progress.activeTasks, 1);
      expect(progress.queuedTasks, 1);
      expect(progress.progressFraction, 0.25);
    });

    test('removing intent frees downloads but preserves Cache Copies', () {
      final repository = InMemoryOfflineRepository();
      repository.saveIntent(novelIntent(t0));
      repository.reconcileIntent(
        intentId: 'intent',
        knownChapterIds: ['c1'],
        now: t0,
      );
      repository.saveCopy(
        cacheCopy(id: 'cache', chapterId: 'c1', storedAt: t0),
      );
      repository.saveCopy(
        downloadedCopy(id: 'download', chapterId: 'c1', storedAt: t0),
      );

      final removal = repository.removeIntent(
        'intent',
        t0.add(const Duration(seconds: 1)),
      );

      expect(removal.removedCopyCount, 1);
      expect(removal.freedBytes, 150);
      expect(repository.copyById('cache'), isNotNull);
      expect(repository.copyById('download'), isNull);
      expect(repository.listTasks().single.state, DownloadTaskState.removed);
    });
  });
}

NovelDownloadIntent novelIntent(DateTime now) {
  return NovelDownloadIntent(
    id: 'intent',
    novelId: 'novel',
    translationSource: TranslationSource.sakura,
    createdAt: now,
  );
}

DownloadTask queuedTask(DateTime now) {
  return DownloadTask.queued(
    id: 'task',
    intentId: 'intent',
    novelId: 'novel',
    chapterId: 'c1',
    translationSource: TranslationSource.sakura,
    now: now,
  );
}

OfflineChapterCopy cacheCopy({
  required String id,
  required String chapterId,
  required DateTime storedAt,
}) {
  return OfflineChapterCopy(
    id: id,
    novelId: 'novel',
    chapterId: chapterId,
    kind: OfflineCopyKind.cacheCopy,
    translationSource: TranslationSource.sakura,
    originalBytes: 100,
    translationBytes: 50,
    storedAt: storedAt,
  );
}

OfflineChapterCopy downloadedCopy({
  required String id,
  required String chapterId,
  required DateTime storedAt,
  int? translationBytes = 50,
  TranslationSource source = TranslationSource.sakura,
}) {
  return OfflineChapterCopy(
    id: id,
    novelId: 'novel',
    chapterId: chapterId,
    kind: OfflineCopyKind.offlineDownload,
    translationSource: source,
    originalBytes: 100,
    translationBytes: translationBytes,
    storedAt: storedAt,
    intentId: 'intent',
  );
}
