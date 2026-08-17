import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/database/app_database.dart';
import 'package:novelia_reader/core/database/sqlite_offline_repository.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/core/offline/content_models.dart';
import 'package:novelia_reader/core/offline/offline_models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 17, 12);

  test('v3 to v4 migration preserves prior local and offline data', () {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    NoveliaDatabase.initialize(database);
    database.execute('''
      DROP TABLE cached_toc_chapters;
      DROP TABLE cached_toc_sections;
      DROP TABLE cached_novels;
      DROP TABLE cached_chapter_payloads;
      DROP INDEX offline_copies_payload_idx;
      ALTER TABLE offline_chapter_copies DROP COLUMN payload_id;
    ''');
    database.execute(
      'INSERT INTO recent_searches '
      '(query, display_order, updated_at_us) VALUES (?, 0, ?);',
      ['旧搜索', t0.microsecondsSinceEpoch],
    );
    database.userVersion = 3;

    final repository = SqliteOfflineRepository.fromDatabase(database);
    addTearDown(repository.close);

    expect(repository.schemaVersion, 4);
    expect(repository.recentSearches(), ['旧搜索']);
    expect(repository.listCachedNovels(), isEmpty);
    repository.upsertChapterPayload(_completePayload(t0));
    expect(
      repository.chapterPayload(novelId: 'novel', chapterId: 'c2'),
      isNotNull,
    );
  });

  group('normalized novel content', () {
    test('round-trips exact empty strings and ordered sections', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final detail = _detail(t0);

      repository.upsertNovelDetail(detail);

      final outline = repository.listCachedNovels().single;
      final restored = repository.novelDetail('novel')!;
      expect(repository.schemaVersion, 4);
      expect(outline.chineseTitle, '');
      expect(outline.chapterCount, 3);
      expect(outline.tags, ['', '幻想']);
      expect(restored.synopsis, '');
      expect(restored.sections.map((section) => section.id), ['s1', 's2']);
      expect(restored.sections.first.title, '');
      expect(restored.sections.first.chapters.map((chapter) => chapter.id), [
        'c1',
        'c2',
      ]);
      expect(restored.sections.first.chapters.first.chineseTitle, '');
      expect(restored.originalUrl, '');
    });

    test('outline refresh preserves already cached detail and TOC', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.upsertNovelDetail(_detail(t0));

      repository.upsertNovelOutline(
        _outline(t0.add(const Duration(minutes: 2)), chineseTitle: '更新标题'),
      );

      final detail = repository.novelDetail('novel')!;
      expect(detail.outline.chineseTitle, '更新标题');
      expect(detail.synopsis, '');
      expect(detail.sections, hasLength(2));
    });

    test('fails closed on corrupt JSON and invalid persisted enum', () {
      final database = sqlite3.openInMemory();
      addTearDown(database.close);
      final repository = SqliteOfflineRepository.fromDatabase(database);
      addTearDown(repository.close);
      repository.upsertNovelOutline(_outline(t0));

      database.execute('UPDATE cached_novels SET tags_json = ? WHERE id = ?;', [
        '["ok", 3]',
        'novel',
      ]);
      expect(repository.listCachedNovels, throwsStateError);

      database.execute(
        'UPDATE cached_novels SET tags_json = ?, publication_state = ? '
        'WHERE id = ?;',
        ['[]', 'not-a-state', 'novel'],
      );
      expect(repository.listCachedNovels, throwsStateError);
    });
  });

  group('real chapter payloads', () {
    test(
      'round-trips originals, per-source arrays, neighbors, and freshness',
      () {
        final repository = SqliteOfflineRepository.openInMemory();
        addTearDown(repository.close);
        final payload = _completePayload(t0);

        repository.upsertChapterPayload(payload);

        final restored = repository.chapterPayload(
          novelId: 'novel',
          chapterId: 'c2',
        )!;
        expect(restored.chineseTitle, '');
        expect(restored.previousChapterId, 'c1');
        expect(restored.nextChapterId, 'c3');
        expect(restored.japaneseBlocks, ['', '原文']);
        expect(restored.translationFor(TranslationSource.sakura)!.blocks, [
          '',
          '译文',
        ]);
        expect(
          restored.translationFor(TranslationSource.gpt)!.availability,
          TranslationAvailability.pending,
        );
        expect(restored.fetchedAt, t0);
        expect(restored.revision, 'r2');
        expect(restored.etag, 'etag-r2');
      },
    );

    test('selects latest revision per chapter in stable chapter order', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.upsertChapterPayload(_completePayload(t0));
      repository.upsertChapterPayload(
        _completePayload(
          t0.add(const Duration(minutes: 1)),
          id: 'payload-new',
          revision: 'r3',
        ),
      );
      repository.upsertChapterPayload(
        _completePayload(
          t0,
          id: 'payload-c1',
          chapterId: 'c1',
          index: 1,
          revision: 'r1',
        ),
      );

      expect(
        repository.chapterPayload(novelId: 'novel', chapterId: 'c2')!.revision,
        'r3',
      );
      expect(
        repository.listChapterPayloads('novel').map((item) => item.chapterId),
        ['c1', 'c2'],
      );
      expect(repository.listChapterPayloads('novel').last.revision, 'r3');
    });

    test(
      'fails closed on corrupt translations JSON and invalid availability',
      () {
        final database = sqlite3.openInMemory();
        addTearDown(database.close);
        final repository = SqliteOfflineRepository.fromDatabase(database);
        addTearDown(repository.close);
        repository.upsertChapterPayload(_completePayload(t0));

        database.execute(
          'UPDATE cached_chapter_payloads SET translations_json = ? '
          'WHERE payload_id = ?;',
          ['{', 'payload-r2'],
        );
        expect(
          () => repository.chapterPayload(novelId: 'novel', chapterId: 'c2'),
          throwsStateError,
        );

        database.execute(
          'UPDATE cached_chapter_payloads SET translations_json = ? '
          'WHERE payload_id = ?;',
          ['{"sakura":{"availability":"alien","blocks":[]}}', 'payload-r2'],
        );
        expect(
          () => repository.chapterPayload(novelId: 'novel', chapterId: 'c2'),
          throwsStateError,
        );
      },
    );

    test('cache payload and Cache Copy are committed atomically', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final payload = _completePayload(t0);
      final copy = _copyFor(
        payload,
        id: 'cache-copy',
        kind: OfflineCopyKind.cacheCopy,
      );

      repository.cacheChapterPayload(payload: payload, copy: copy);

      expect(repository.copyById(copy.id)!.payloadId, payload.id);
      expect(
        repository.chapterPayload(novelId: 'novel', chapterId: 'c2')!.id,
        payload.id,
      );
    });

    test('a newer semantic Cache Copy replaces a legacy timestamped ID', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final oldPayload = _completePayload(
        t0,
        id: 'payload-old',
        revision: 'r1',
      );
      final newPayload = _completePayload(
        t0.add(const Duration(minutes: 1)),
        id: 'payload-new',
        revision: 'r2',
      );
      repository.cacheChapterPayload(
        payload: oldPayload,
        copy: _copyFor(
          oldPayload,
          id: 'cache:legacy:${t0.microsecondsSinceEpoch}',
          kind: OfflineCopyKind.cacheCopy,
        ),
      );

      repository.cacheChapterPayload(
        payload: newPayload,
        copy: _copyFor(
          newPayload,
          id: 'cache::novel::c2::sakura',
          kind: OfflineCopyKind.cacheCopy,
        ),
      );

      final copies = repository.listCopies(kind: OfflineCopyKind.cacheCopy);
      expect(copies, hasLength(1));
      expect(copies.single.id, 'cache::novel::c2::sakura');
      expect(copies.single.payloadId, newPayload.id);
      expect(repository.chapterPayloadById(oldPayload.id), isNull);
      expect(repository.chapterPayloadById(newPayload.id), isNotNull);
    });

    test(
      'payload, protected copy, and task completion are one transaction',
      () {
        final repository = SqliteOfflineRepository.openInMemory();
        addTearDown(repository.close);
        final task = _storingTask(repository, t0);
        final payload = _completePayload(t0);
        final copy = _copyFor(
          payload,
          id: 'download-copy',
          kind: OfflineCopyKind.offlineDownload,
        );

        repository.commitDownloadedChapter(
          taskId: task.id,
          payload: payload,
          copy: copy,
          now: t0.add(const Duration(seconds: 4)),
        );

        expect(repository.taskById(task.id)!.state, DownloadTaskState.stored);
        expect(repository.copyById(copy.id)!.payloadId, payload.id);
        expect(
          repository.chapterPayload(novelId: 'novel', chapterId: 'c2')!.id,
          payload.id,
        );
      },
    );

    test('invalid atomic commit rolls back payload, copy, and task', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final task = _storingTask(repository, t0);
      final payload = _completePayload(t0);
      final mismatched = OfflineChapterCopy(
        id: 'bad-copy',
        novelId: payload.novelId,
        chapterId: payload.chapterId,
        kind: OfflineCopyKind.offlineDownload,
        translationSource: TranslationSource.sakura,
        originalBytes: 10,
        translationBytes: null,
        storedAt: t0,
        intentId: 'intent',
        payloadId: payload.id,
        revision: payload.revision,
        etag: payload.etag,
      );

      expect(
        () => repository.commitDownloadedChapter(
          taskId: task.id,
          payload: payload,
          copy: mismatched,
          now: t0,
        ),
        throwsStateError,
      );
      expect(repository.copyById('bad-copy'), isNull);
      expect(
        repository.chapterPayload(novelId: 'novel', chapterId: 'c2'),
        isNull,
      );
      expect(repository.taskById(task.id)!.state, DownloadTaskState.storing);
    });

    test(
      'removing cache keeps protected payload readable until intent removal',
      () {
        final repository = SqliteOfflineRepository.openInMemory();
        addTearDown(repository.close);
        repository.upsertNovelDetail(_detail(t0));
        final task = _storingTask(repository, t0);
        final protectedPayload = _completePayload(t0);
        repository.commitDownloadedChapter(
          taskId: task.id,
          payload: protectedPayload,
          copy: _copyFor(
            protectedPayload,
            id: 'download-copy',
            kind: OfflineCopyKind.offlineDownload,
          ),
          now: t0,
        );
        final cachePayload = _completePayload(
          t0,
          id: 'cache-payload',
          chapterId: 'c1',
          index: 1,
          revision: 'cache-r1',
        );
        repository.cacheChapterPayload(
          payload: cachePayload,
          copy: _copyFor(
            cachePayload,
            id: 'cache-copy',
            kind: OfflineCopyKind.cacheCopy,
          ),
        );

        final removal = repository.removeCachedNovel('novel');

        expect(removal.removedCacheCopyCount, 1);
        expect(removal.removedPayloadCount, 1);
        expect(removal.retainedProtectedPayloadCount, 1);
        expect(removal.retainedDownloadManifest, isTrue);
        expect(repository.novelDetail('novel'), isNotNull);
        expect(repository.copyById('cache-copy'), isNull);
        expect(
          repository
              .chapterPayload(novelId: 'novel', chapterId: 'c2')!
              .japaneseBlocks,
          ['', '原文'],
        );

        repository.removeIntent('intent', t0.add(const Duration(days: 1)));
        expect(
          repository.chapterPayload(novelId: 'novel', chapterId: 'c2'),
          isNull,
        );
        repository.removeCachedNovel('novel');
        expect(repository.novelDetail('novel'), isNull);
      },
    );
  });
}

CachedNovelOutline _outline(DateTime fetchedAt, {String chineseTitle = ''}) {
  return CachedNovelOutline(
    id: 'novel',
    chineseTitle: chineseTitle,
    japaneseTitle: '原題',
    author: '',
    contentSource: 'syosetu',
    publicationState: CachedNovelState.ongoing,
    chapterCount: 3,
    wordCount: 1200,
    updatedAt: fetchedAt.subtract(const Duration(hours: 1)),
    tags: const ['', '幻想'],
    translationCoverage: [
      CachedTranslationCoverage(
        source: TranslationSource.sakura,
        translatedChapters: 2,
        totalChapters: 3,
      ),
    ],
    fetchedAt: fetchedAt,
    revision: 'novel-r1',
    etag: 'novel-etag',
  );
}

CachedNovelDetail _detail(DateTime fetchedAt) {
  return CachedNovelDetail(
    outline: _outline(fetchedAt),
    synopsis: '',
    points: 42,
    views: 99,
    originalUrl: '',
    sections: [
      CachedTocSection(
        id: 's1',
        title: '',
        chapters: [
          CachedTocChapter(
            id: 'c1',
            index: 1,
            chineseTitle: '',
            japaneseTitle: '一',
          ),
          CachedTocChapter(
            id: 'c2',
            index: 2,
            chineseTitle: '二',
            japaneseTitle: '',
          ),
        ],
      ),
      CachedTocSection(
        id: 's2',
        title: '第二部',
        chapters: [
          CachedTocChapter(
            id: 'c3',
            index: 3,
            chineseTitle: '三',
            japaneseTitle: '三',
          ),
        ],
      ),
    ],
  );
}

CachedChapterPayload _completePayload(
  DateTime fetchedAt, {
  String id = 'payload-r2',
  String chapterId = 'c2',
  int index = 2,
  String revision = 'r2',
}) {
  return CachedChapterPayload(
    id: id,
    novelId: 'novel',
    chapterId: chapterId,
    index: index,
    chineseTitle: '',
    japaneseTitle: '第二話',
    previousChapterId: index > 1 ? 'c${index - 1}' : null,
    nextChapterId: 'c${index + 1}',
    publishedAt: fetchedAt.subtract(const Duration(days: 1)),
    japaneseBlocks: const ['', '原文'],
    translations: {
      TranslationSource.sakura: CachedChapterTranslation(
        availability: TranslationAvailability.complete,
        blocks: const ['', '译文'],
      ),
      TranslationSource.gpt: CachedChapterTranslation(
        availability: TranslationAvailability.pending,
        blocks: const [],
      ),
    },
    fetchedAt: fetchedAt,
    revision: revision,
    etag: 'etag-$revision',
  );
}

DownloadTask _storingTask(SqliteOfflineRepository repository, DateTime now) {
  repository.saveIntent(
    NovelDownloadIntent(
      id: 'intent',
      novelId: 'novel',
      translationSource: TranslationSource.sakura,
      createdAt: now,
    ),
  );
  var task = repository
      .reconcileIntent(intentId: 'intent', knownChapterIds: ['c2'], now: now)
      .single;
  task = task.beginFetching(now.add(const Duration(seconds: 1)));
  repository.saveTask(task);
  task = task.beginValidation(now.add(const Duration(seconds: 2)));
  repository.saveTask(task);
  task = task.beginStoring(now.add(const Duration(seconds: 3)));
  repository.saveTask(task);
  return task;
}

OfflineChapterCopy _copyFor(
  CachedChapterPayload payload, {
  required String id,
  required OfflineCopyKind kind,
}) {
  return OfflineChapterCopy(
    id: id,
    novelId: payload.novelId,
    chapterId: payload.chapterId,
    kind: kind,
    translationSource: TranslationSource.sakura,
    originalBytes: 10,
    translationBytes: 10,
    storedAt: payload.fetchedAt,
    intentId: kind == OfflineCopyKind.offlineDownload ? 'intent' : null,
    payloadId: payload.id,
    revision: payload.revision,
    etag: payload.etag,
  );
}
