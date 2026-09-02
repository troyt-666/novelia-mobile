import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/content_repository.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/core/offline/offline_repository.dart';

void main() {
  group('SQLite protected chapter refresh', () {
    late _Harness harness;
    final t0 = DateTime.utc(2026, 8, 18);

    setUp(() {
      final repository = SqliteOfflineRepository.openInMemory();
      harness = _Harness(repository, repository, repository.close);
    });
    tearDown(() => harness.close());

    test('atomically upgrades Translation Pending to complete', () {
      final stored = _storeInitial(harness, t0);
      final taskBefore = harness.offline.taskById(stored.taskId)!;
      final complete = _payload(
        id: 'payload-r2',
        revision: 'r2',
        etag: 'etag-r2',
        fetchedAt: t0.add(const Duration(hours: 1)),
        japaneseBlocks: const ['新しい原文', ''],
        availability: TranslationAvailability.complete,
        translationBlocks: const ['新译文', ''],
      );
      final replacement = _replacementCopy(
        stored.copy,
        complete,
        originalBytes: 240,
        translationBytes: 180,
      );

      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: complete,
        copy: replacement,
      );

      final taskAfter = harness.offline.taskById(stored.taskId)!;
      _expectTaskUnchanged(taskBefore, taskAfter);
      final copyAfter = harness.offline.copyById(stored.copy.id)!;
      expect(copyAfter.payloadId, 'payload-r2');
      expect(copyAfter.translationBytes, 180);
      expect(copyAfter.originalBytes, 240);
      expect(copyAfter.revision, 'r2');
      expect(copyAfter.etag, 'etag-r2');
      expect(harness.content.chapterPayloadById('payload-r2')!.japaneseBlocks, [
        '新しい原文',
        '',
      ]);
      expect(harness.content.chapterPayloadById('payload-r1'), isNull);
    });

    test('refreshes pending freshness without inventing a translation', () {
      final stored = _storeInitial(harness, t0);
      final taskBefore = harness.offline.taskById(stored.taskId)!;
      final refreshedPending = _payload(
        id: 'payload-r1',
        revision: 'r1',
        etag: 'etag-r1',
        fetchedAt: t0.add(const Duration(minutes: 15)),
        japaneseBlocks: const ['原文', ''],
        availability: TranslationAvailability.pending,
      );
      final replacement = _replacementCopy(
        stored.copy,
        refreshedPending,
        originalBytes: 130,
        translationBytes: null,
      );

      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: refreshedPending,
        copy: replacement,
      );

      _expectTaskUnchanged(
        taskBefore,
        harness.offline.taskById(stored.taskId)!,
      );
      expect(harness.offline.copyById(stored.copy.id)!.hasTranslation, false);
      expect(
        harness.content.chapterPayloadById('payload-r1')!.fetchedAt,
        refreshedPending.fetchedAt,
      );
    });

    test('repoints a pending copy when the Japanese revision changes', () {
      final stored = _storeInitial(harness, t0);
      final revisedOriginal = _payload(
        id: 'payload-original-r2',
        revision: 'original-r2',
        etag: 'original-etag-r2',
        fetchedAt: t0.add(const Duration(hours: 2)),
        japaneseBlocks: const ['改稿された原文'],
        availability: TranslationAvailability.pending,
      );

      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: revisedOriginal,
        copy: _replacementCopy(
          stored.copy,
          revisedOriginal,
          originalBytes: 300,
          translationBytes: null,
        ),
      );

      expect(
        harness.content
            .chapterPayloadById('payload-original-r2')!
            .japaneseBlocks,
        ['改稿された原文'],
      );
      expect(harness.content.chapterPayloadById('payload-r1'), isNull);
      expect(harness.offline.copyById(stored.copy.id)!.revision, 'original-r2');
    });

    test('can replace an invalid translation with a complete revision', () {
      final stored = _storeInitial(harness, t0);
      final invalid = _payload(
        id: 'payload-invalid',
        revision: 'invalid-r1',
        etag: 'invalid-etag',
        fetchedAt: t0.add(const Duration(minutes: 10)),
        japaneseBlocks: const ['一', '二'],
        availability: TranslationAvailability.invalid,
        translationBlocks: const ['只有一行'],
      );
      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: invalid,
        copy: _replacementCopy(
          stored.copy,
          invalid,
          originalBytes: 120,
          translationBytes: null,
        ),
      );
      final complete = _payload(
        id: 'payload-valid',
        revision: 'valid-r2',
        etag: 'valid-etag',
        fetchedAt: t0.add(const Duration(minutes: 20)),
        japaneseBlocks: const ['一', '二'],
        availability: TranslationAvailability.complete,
        translationBlocks: const ['一', '二'],
      );

      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: complete,
        copy: _replacementCopy(
          harness.offline.copyById(stored.copy.id)!,
          complete,
          originalBytes: 120,
          translationBytes: 80,
        ),
      );

      expect(harness.content.chapterPayloadById('payload-invalid'), isNull);
      expect(harness.offline.copyById(stored.copy.id)!.translationBytes, 80);
      expect(
        harness.offline.taskById(stored.taskId)!.state,
        DownloadTaskState.stored,
      );
    });

    test('retains an old payload while another copy still references it', () {
      final stored = _storeInitial(harness, t0);
      harness.offline.saveIntent(
        NovelDownloadIntent(
          id: 'other-intent',
          novelId: 'novel',
          translationSource: TranslationSource.sakura,
          createdAt: t0,
        ),
      );
      var otherTask = harness.offline
          .reconcileIntent(
            intentId: 'other-intent',
            knownChapterIds: const ['chapter'],
            now: t0,
          )
          .single;
      otherTask = otherTask.beginFetching(t0);
      harness.offline.saveTask(otherTask);
      otherTask = otherTask.beginValidation(t0);
      harness.offline.saveTask(otherTask);
      otherTask = otherTask.beginStoring(t0);
      harness.offline.saveTask(otherTask);
      final oldPayload = harness.content.chapterPayloadById('payload-r1')!;
      harness.content.commitDownloadedChapter(
        taskId: otherTask.id,
        payload: oldPayload,
        copy: OfflineChapterCopy(
          id: 'other-download',
          novelId: 'novel',
          chapterId: 'chapter',
          kind: OfflineCopyKind.offlineDownload,
          translationSource: TranslationSource.sakura,
          originalBytes: 100,
          translationBytes: null,
          storedAt: t0,
          intentId: 'other-intent',
          payloadId: oldPayload.id,
          revision: oldPayload.revision,
          etag: oldPayload.etag,
        ),
        now: t0,
      );
      final complete = _payload(
        id: 'payload-r2',
        revision: 'r2',
        etag: 'etag-r2',
        fetchedAt: t0.add(const Duration(hours: 1)),
        japaneseBlocks: const ['原文'],
        availability: TranslationAvailability.complete,
        translationBlocks: const ['译文'],
      );

      harness.content.refreshDownloadedChapter(
        taskId: stored.taskId,
        payload: complete,
        copy: _replacementCopy(
          stored.copy,
          complete,
          originalBytes: 120,
          translationBytes: 90,
        ),
      );

      expect(harness.content.chapterPayloadById('payload-r1'), isNotNull);
      harness.offline.removeIntent('other-intent', t0);
      expect(harness.content.chapterPayloadById('payload-r1'), isNull);
      expect(harness.content.chapterPayloadById('payload-r2'), isNotNull);
    });

    test(
      'rolls back mismatches without touching task, copy, or other intent',
      () {
        final stored = _storeInitial(harness, t0);
        harness.offline.saveIntent(
          NovelDownloadIntent(
            id: 'other-intent',
            novelId: 'novel',
            translationSource: TranslationSource.sakura,
            createdAt: t0,
          ),
        );
        final unrelatedPayload = _payload(
          id: 'payload-unrelated',
          revision: 'unrelated',
          etag: 'unrelated-etag',
          fetchedAt: t0,
          japaneseBlocks: const ['別'],
          availability: TranslationAvailability.pending,
        );
        final cacheCopy = OfflineChapterCopy(
          id: 'unrelated-cache',
          novelId: 'novel',
          chapterId: 'chapter',
          kind: OfflineCopyKind.cacheCopy,
          translationSource: TranslationSource.sakura,
          originalBytes: 10,
          translationBytes: null,
          storedAt: t0,
          payloadId: unrelatedPayload.id,
          revision: unrelatedPayload.revision,
          etag: unrelatedPayload.etag,
        );
        harness.content.cacheChapterPayload(
          payload: unrelatedPayload,
          copy: cacheCopy,
        );
        final taskBefore = harness.offline.taskById(stored.taskId)!;
        final copyBefore = harness.offline.copyById(stored.copy.id)!;
        final mismatchedPayload = _payload(
          id: 'payload-bad',
          revision: 'bad',
          etag: 'bad-etag',
          fetchedAt: t0.add(const Duration(hours: 1)),
          japaneseBlocks: const ['原文'],
          availability: TranslationAvailability.complete,
          translationBlocks: const ['译文'],
        );
        final wrongIntentCopy = OfflineChapterCopy(
          id: stored.copy.id,
          novelId: stored.copy.novelId,
          chapterId: stored.copy.chapterId,
          kind: OfflineCopyKind.offlineDownload,
          translationSource: stored.copy.translationSource,
          originalBytes: 200,
          translationBytes: 100,
          storedAt: mismatchedPayload.fetchedAt,
          intentId: 'other-intent',
          payloadId: mismatchedPayload.id,
          revision: mismatchedPayload.revision,
          etag: mismatchedPayload.etag,
        );

        expect(
          () => harness.content.refreshDownloadedChapter(
            taskId: stored.taskId,
            payload: mismatchedPayload,
            copy: wrongIntentCopy,
          ),
          throwsStateError,
        );

        _expectTaskUnchanged(
          taskBefore,
          harness.offline.taskById(stored.taskId)!,
        );
        final copyAfter = harness.offline.copyById(stored.copy.id)!;
        expect(copyAfter.payloadId, copyBefore.payloadId);
        expect(copyAfter.intentId, 'intent');
        expect(harness.content.chapterPayloadById('payload-bad'), isNull);
        expect(
          harness.offline.copyById('unrelated-cache')!.payloadId,
          'payload-unrelated',
        );
        expect(harness.offline.intentById('other-intent'), isNotNull);
      },
    );
  });
}

class _Harness {
  const _Harness(this.offline, this.content, this.close);

  final OfflineRepository offline;
  final ContentRepository content;
  final void Function() close;
}

({String taskId, OfflineChapterCopy copy}) _storeInitial(
  _Harness harness,
  DateTime now,
) {
  harness.offline.saveIntent(
    NovelDownloadIntent(
      id: 'intent',
      novelId: 'novel',
      translationSource: TranslationSource.sakura,
      createdAt: now,
    ),
  );
  var task = harness.offline
      .reconcileIntent(
        intentId: 'intent',
        knownChapterIds: const ['chapter'],
        now: now,
      )
      .single;
  task = task.beginFetching(now.add(const Duration(seconds: 1)));
  harness.offline.saveTask(task);
  task = task.beginValidation(now.add(const Duration(seconds: 2)));
  harness.offline.saveTask(task);
  task = task.beginStoring(now.add(const Duration(seconds: 3)));
  harness.offline.saveTask(task);
  final payload = _payload(
    id: 'payload-r1',
    revision: 'r1',
    etag: 'etag-r1',
    fetchedAt: now,
    japaneseBlocks: const ['原文', ''],
    availability: TranslationAvailability.pending,
  );
  final copy = OfflineChapterCopy(
    id: 'download-copy',
    novelId: 'novel',
    chapterId: 'chapter',
    kind: OfflineCopyKind.offlineDownload,
    translationSource: TranslationSource.sakura,
    originalBytes: 100,
    translationBytes: null,
    storedAt: now,
    intentId: 'intent',
    payloadId: payload.id,
    revision: payload.revision,
    etag: payload.etag,
  );
  harness.content.commitDownloadedChapter(
    taskId: task.id,
    payload: payload,
    copy: copy,
    now: now.add(const Duration(seconds: 4)),
  );
  return (taskId: task.id, copy: copy);
}

CachedChapterPayload _payload({
  required String id,
  required String revision,
  required String etag,
  required DateTime fetchedAt,
  required List<String> japaneseBlocks,
  required TranslationAvailability availability,
  List<String> translationBlocks = const [],
}) {
  return CachedChapterPayload(
    id: id,
    novelId: 'novel',
    chapterId: 'chapter',
    index: 1,
    chineseTitle: '',
    japaneseTitle: '',
    previousChapterId: null,
    nextChapterId: null,
    publishedAt: null,
    japaneseBlocks: japaneseBlocks,
    translations: {
      TranslationSource.sakura: CachedChapterTranslation(
        availability: availability,
        blocks: translationBlocks,
      ),
    },
    fetchedAt: fetchedAt,
    revision: revision,
    etag: etag,
  );
}

OfflineChapterCopy _replacementCopy(
  OfflineChapterCopy existing,
  CachedChapterPayload payload, {
  required int originalBytes,
  required int? translationBytes,
}) {
  return OfflineChapterCopy(
    id: existing.id,
    novelId: existing.novelId,
    chapterId: existing.chapterId,
    kind: existing.kind,
    translationSource: existing.translationSource,
    originalBytes: originalBytes,
    translationBytes: translationBytes,
    storedAt: payload.fetchedAt,
    lastReadAt: existing.lastReadAt,
    intentId: existing.intentId,
    payloadId: payload.id,
    revision: payload.revision,
    etag: payload.etag,
  );
}

void _expectTaskUnchanged(DownloadTask before, DownloadTask after) {
  expect(after.id, before.id);
  expect(after.state, DownloadTaskState.stored);
  expect(after.revision, before.revision);
  expect(after.updatedAt, before.updatedAt);
  expect(after.storedCopyId, before.storedCopyId);
  expect(after.intentId, before.intentId);
  expect(after.novelId, before.novelId);
  expect(after.chapterId, before.chapterId);
  expect(after.translationSource, before.translationSource);
}
