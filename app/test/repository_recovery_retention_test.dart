import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/database/sqlite_offline_repository.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/core/offline/content_models.dart';
import 'package:novelia_reader/core/offline/content_repository.dart';
import 'package:novelia_reader/core/offline/offline_models.dart';
import 'package:novelia_reader/core/offline/offline_repository.dart';

void main() {
  final factories = <({String name, _Harness Function() create})>[
    (
      name: 'memory',
      create: () {
        final repository = InMemoryOfflineRepository();
        return _Harness(repository, repository);
      },
    ),
    (
      name: 'sqlite',
      create: () {
        final repository = SqliteOfflineRepository.openInMemory();
        return _Harness(repository, repository, repository.close);
      },
    ),
  ];

  for (final factory in factories) {
    group('${factory.name} repository', () {
      test(
        'atomically requeues every recoverable task with clean counters',
        () {
          final harness = factory.create();
          addTearDown(harness.close);
          final repository = harness.offline;
          final tasks = _seedTaskStates(repository);
          final priorRevisions = {
            for (final task in repository.listTasks()) task.id: task.revision,
          };

          final recovered = repository.requeueInterruptedTasks(
            intentId: _intentId,
            now: _t0.add(const Duration(minutes: 1)),
          );

          expect(recovered.map((task) => task.chapterId).toSet(), {
            'active',
            'retryable',
            'paused',
          });
          for (final task in recovered) {
            expect(task.state, DownloadTaskState.queued);
            expect(task.bytesReceived, 0);
            expect(task.totalBytes, isNull);
            expect(task.failure, isNull);
            expect(task.storedCopyId, isNull);
            expect(task.revision, priorRevisions[task.id]! + 1);
          }
          expect(
            repository.taskById(tasks['permanent']!.id)!.state,
            DownloadTaskState.failed,
          );
          expect(
            repository.taskById(tasks['queued']!.id)!.revision,
            priorRevisions[tasks['queued']!.id],
          );
        },
      );

      test('does not restart tasks belonging to a disabled intent', () {
        final harness = factory.create();
        addTearDown(harness.close);
        final repository = harness.offline;
        _saveIntent(repository, enabled: false);
        final queued = repository
            .reconcileIntent(
              intentId: _intentId,
              knownChapterIds: const [],
              now: _t0,
            )
            .toList();
        expect(queued, isEmpty);

        // Seed before disabling so the paused task represents an intentional
        // paused intent rather than an interrupted enabled one.
        repository.saveIntent(_intent(enabled: true));
        final task = repository
            .reconcileIntent(
              intentId: _intentId,
              knownChapterIds: const ['paused'],
              now: _t0,
            )
            .single;
        final fetching = task.beginFetching(_t0, expectedBytes: 80);
        repository.saveTask(fetching);
        repository.pauseIntent(_intentId, _t0.add(const Duration(seconds: 1)));

        expect(
          repository.requeueInterruptedTasks(
            intentId: _intentId,
            now: _t0.add(const Duration(seconds: 2)),
          ),
          isEmpty,
        );
        expect(repository.taskById(task.id)!.state, DownloadTaskState.paused);
      });

      test('cache removal retains manifest and protected payload', () {
        final harness = factory.create();
        addTearDown(harness.close);
        _seedProtectedNovel(harness);

        final removal = harness.content.removeCachedNovel(_novelId);

        expect(removal.retainedDownloadManifest, isTrue);
        expect(removal.retainedProtectedPayloadCount, 1);
        expect(
          harness.content.listCachedNovels().map((novel) => novel.id),
          contains(_novelId),
        );
        final detail = harness.content.novelDetail(_novelId)!;
        expect(detail.sections.single.chapters.single.id, _chapterId);
        final copy = harness.offline
            .listCopies(kind: OfflineCopyKind.offlineDownload)
            .single;
        expect(
          harness.content.chapterPayloadById(copy.payloadId!)!.japaneseBlocks,
          const ['原文', ''],
        );
      });
    });
  }

  test('SQLite restart recovery survives two file close/reopen boundaries', () {
    final directory = Directory.systemTemp.createTempSync(
      'novelia-task-recovery-',
    );
    final path = '${directory.path}/reader.sqlite3';
    var repository = SqliteOfflineRepository.openFile(path);
    addTearDown(() {
      repository.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    _saveIntent(repository);
    final queued = repository
        .reconcileIntent(
          intentId: _intentId,
          knownChapterIds: const ['active'],
          now: _t0,
        )
        .single;
    var active = queued.beginFetching(_t0, expectedBytes: 100);
    repository.saveTask(active);
    active = active.reportFetchProgress(
      _t0.add(const Duration(seconds: 1)),
      bytesReceived: 60,
    );
    repository.saveTask(active);
    repository.close();

    repository = SqliteOfflineRepository.openFile(path);
    final recovered = repository.requeueInterruptedTasks(
      intentId: _intentId,
      now: _t0.add(const Duration(minutes: 1)),
    );
    expect(recovered.single.revision, active.revision + 1);
    repository.close();

    repository = SqliteOfflineRepository.openFile(path);
    final restored = repository.taskById(active.id)!;
    expect(restored.state, DownloadTaskState.queued);
    expect(restored.bytesReceived, 0);
    expect(restored.totalBytes, isNull);
  });

  test(
    'SQLite protected manifest remains readable after cache removal/reopen',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'novelia-manifest-retention-',
      );
      final path = '${directory.path}/reader.sqlite3';
      var repository = SqliteOfflineRepository.openFile(path);
      addTearDown(() {
        repository.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      _seedProtectedNovel(_Harness(repository, repository));
      final removal = repository.removeCachedNovel(_novelId);
      expect(removal.retainedDownloadManifest, isTrue);
      repository.close();

      repository = SqliteOfflineRepository.openFile(path);
      expect(repository.listCachedNovels().single.id, _novelId);
      expect(
        repository.novelDetail(_novelId)!.sections.single.chapters.single.id,
        _chapterId,
      );
      final copy = repository
          .listCopies(kind: OfflineCopyKind.offlineDownload)
          .single;
      expect(repository.chapterPayloadById(copy.payloadId!), isNotNull);
    },
  );
}

const _intentId = 'intent';
const _novelId = 'syosetu/novel';
const _chapterId = 'chapter-1';
final _t0 = DateTime.utc(2026, 8, 17, 12);

class _Harness {
  const _Harness(this.offline, this.content, [this._onClose]);

  final OfflineRepository offline;
  final ContentRepository content;
  final void Function()? _onClose;

  void close() => _onClose?.call();
}

NovelDownloadIntent _intent({bool enabled = true}) {
  return NovelDownloadIntent(
    id: _intentId,
    novelId: _novelId,
    translationSource: TranslationSource.sakura,
    createdAt: _t0,
    enabled: enabled,
  );
}

void _saveIntent(OfflineRepository repository, {bool enabled = true}) {
  repository.saveIntent(_intent(enabled: enabled));
}

Map<String, DownloadTask> _seedTaskStates(OfflineRepository repository) {
  _saveIntent(repository);
  final tasks = {
    for (final task in repository.reconcileIntent(
      intentId: _intentId,
      knownChapterIds: const [
        'active',
        'retryable',
        'paused',
        'permanent',
        'queued',
      ],
      now: _t0,
    ))
      task.chapterId: task,
  };

  var active = tasks['active']!.beginFetching(_t0, expectedBytes: 100);
  repository.saveTask(active);
  active = active.reportFetchProgress(
    _t0.add(const Duration(seconds: 1)),
    bytesReceived: 60,
  );
  repository.saveTask(active);

  var retryable = tasks['retryable']!.beginFetching(_t0, expectedBytes: 90);
  repository.saveTask(retryable);
  retryable = retryable.reportFetchProgress(
    _t0.add(const Duration(seconds: 1)),
    bytesReceived: 45,
  );
  repository.saveTask(retryable);
  retryable = retryable.fail(
    _t0.add(const Duration(seconds: 2)),
    const DownloadFailure(
      kind: DownloadFailureKind.network,
      message: 'retry',
      retryable: true,
    ),
  );
  repository.saveTask(retryable);

  var paused = tasks['paused']!.beginFetching(_t0, expectedBytes: 80);
  repository.saveTask(paused);
  paused = paused.reportFetchProgress(
    _t0.add(const Duration(seconds: 1)),
    bytesReceived: 20,
  );
  repository.saveTask(paused);
  repository.saveTask(paused.pause(_t0.add(const Duration(seconds: 2))));

  var permanent = tasks['permanent']!.beginFetching(_t0);
  repository.saveTask(permanent);
  permanent = permanent.fail(
    _t0.add(const Duration(seconds: 1)),
    const DownloadFailure(
      kind: DownloadFailureKind.validation,
      message: 'permanent',
      retryable: false,
    ),
  );
  repository.saveTask(permanent);
  return tasks;
}

void _seedProtectedNovel(_Harness harness) {
  harness.content.upsertNovelDetail(_detail());
  _saveIntent(harness.offline);
  var task = harness.offline
      .reconcileIntent(
        intentId: _intentId,
        knownChapterIds: const [_chapterId],
        now: _t0,
      )
      .single;
  task = task.beginFetching(_t0, expectedBytes: 10);
  harness.offline.saveTask(task);
  task = task.reportFetchProgress(_t0, bytesReceived: 10);
  harness.offline.saveTask(task);
  task = task.beginValidation(_t0);
  harness.offline.saveTask(task);
  task = task.beginStoring(_t0);
  harness.offline.saveTask(task);
  final payload = _payload();
  harness.content.commitDownloadedChapter(
    taskId: task.id,
    payload: payload,
    copy: OfflineChapterCopy(
      id: 'protected-copy',
      novelId: _novelId,
      chapterId: _chapterId,
      kind: OfflineCopyKind.offlineDownload,
      translationSource: TranslationSource.sakura,
      originalBytes: 6,
      translationBytes: 6,
      storedAt: _t0,
      intentId: _intentId,
      payloadId: payload.id,
      revision: payload.revision,
    ),
    now: _t0,
  );
}

CachedNovelDetail _detail() {
  return CachedNovelDetail(
    outline: CachedNovelOutline(
      id: _novelId,
      chineseTitle: '小说',
      japaneseTitle: '小説',
      author: '',
      contentSource: 'Syosetu',
      publicationState: CachedNovelState.ongoing,
      chapterCount: 1,
      wordCount: null,
      updatedAt: _t0,
      tags: const [],
      translationCoverage: [
        CachedTranslationCoverage(
          source: TranslationSource.sakura,
          translatedChapters: 1,
          totalChapters: 1,
        ),
      ],
      fetchedAt: _t0,
    ),
    synopsis: '',
    points: null,
    views: null,
    originalUrl: null,
    sections: [
      CachedTocSection(
        id: 'section',
        title: '正文',
        chapters: [
          CachedTocChapter(
            id: _chapterId,
            index: 0,
            chineseTitle: '第一章',
            japaneseTitle: '第一章',
          ),
        ],
      ),
    ],
  );
}

CachedChapterPayload _payload() {
  return CachedChapterPayload(
    id: '$_novelId::$_chapterId::r1',
    novelId: _novelId,
    chapterId: _chapterId,
    index: 0,
    chineseTitle: '第一章',
    japaneseTitle: '第一章',
    previousChapterId: null,
    nextChapterId: null,
    publishedAt: null,
    japaneseBlocks: const ['原文', ''],
    translations: {
      TranslationSource.sakura: CachedChapterTranslation(
        availability: TranslationAvailability.complete,
        blocks: const ['译文', ''],
      ),
    },
    fetchedAt: _t0,
    revision: 'r1',
  );
}
