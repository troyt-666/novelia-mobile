import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 17, 1);

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

        expect(chapter.targetChapterIds(['c1', 'c2', 'c3']), ['c2']);
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
