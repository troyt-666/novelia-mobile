import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/app_database.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 17, 8);

  group('database schema', () {
    test('new in-memory database opens at current healthy schema', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);

      expect(repository.schemaVersion, NoveliaDatabase.currentSchemaVersion);
      expect(repository.passesIntegrityCheck, isTrue);
      expect(repository.listIntents(), isEmpty);
      expect(repository.listReadingProgress(), isEmpty);
    });

    test('migrates v1 through the current schema without losing records', () {
      final database = sqlite3.openInMemory();
      addTearDown(database.close);
      _createVersion1Fixture(database, t0);

      final repository = SqliteOfflineRepository.fromDatabase(database);
      addTearDown(repository.close);

      expect(repository.schemaVersion, NoveliaDatabase.currentSchemaVersion);
      final intent = repository.intentById('legacy-intent');
      expect(intent, isA<NovelDownloadIntent>());
      expect(intent!.translationSource, TranslationSource.gpt);
      expect(repository.copyById('legacy-copy')!.hasTranslation, isFalse);
      expect(repository.recentSearches(), isEmpty);

      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: 'legacy-novel',
          position: const ReadingPosition(chapterId: 'c1', blockId: 'b4'),
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      expect(
        repository.readingProgressFor('legacy-novel')!.position.blockId,
        'b4',
      );
      expect(repository.passesIntegrityCheck, isTrue);
    });

    test('rejects a database created by a newer application', () {
      final database = sqlite3.openInMemory()..userVersion = 99;
      addTearDown(database.close);

      expect(
        () => SqliteOfflineRepository.fromDatabase(database),
        throwsStateError,
      );
    });

    test('migrates v5 reader settings with compatibility defaults', () {
      final database = sqlite3.openInMemory();
      addTearDown(database.close);
      _createVersion5SettingsFixture(database, t0);

      final repository = SqliteOfflineRepository.fromDatabase(database);
      addTearDown(repository.close);
      final settings = repository.appSettings()!.readerSettings;

      expect(repository.schemaVersion, 7);
      expect(settings.layoutMode, ReaderLayoutMode.scroll);
      expect(settings.palette, ReaderPalette.automatic);
      expect(settings.fontFamily, ReaderFontFamily.systemSans);
      expect(settings.bodyBold, isFalse);
      expect(settings.paragraphSpacing, 15);
      expect(settings.pageMargin, 24);
      expect(settings.columnLayout, ReaderColumnLayout.automatic);
      expect(
        settings.orientationPreference,
        ReaderOrientationPreference.followDevice,
      );
      expect(settings.textSelectionEnabled, isTrue);
      expect(settings.tapPageTurnEnabled, isTrue);
    });
  });

  group('durable offline repository', () {
    test('rehydrates intent, failed task, copy, and local state from disk', () {
      final directory = Directory.systemTemp.createTempSync('novelia-sqlite-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/reader.sqlite3';

      var repository = SqliteOfflineRepository.openFile(databasePath);
      repository.saveIntent(_novelIntent(t0));
      var task = repository
          .reconcileIntent(intentId: 'intent', knownChapterIds: ['c1'], now: t0)
          .single;
      task = task.beginFetching(
        t0.add(const Duration(seconds: 1)),
        expectedBytes: 500,
      );
      repository.saveTask(task);
      task = task.reportFetchProgress(
        t0.add(const Duration(seconds: 2)),
        bytesReceived: 120,
      );
      repository.saveTask(task);
      task = task.fail(
        t0.add(const Duration(seconds: 3)),
        DownloadFailure.insufficientStorage(
          requiredBytes: 380,
          availableBytes: 200,
        ),
      );
      repository.saveTask(task);
      _saveCacheCopy(
        repository,
        id: 'cache-c1',
        chapterId: 'c1',
        storedAt: t0,
        translationBytes: null,
      );
      _saveLocalState(repository, t0);
      repository.close();

      repository = SqliteOfflineRepository.openFile(databasePath);
      addTearDown(repository.close);

      expect(repository.listIntents(), hasLength(1));
      final restoredTask = repository.listTasks().single;
      expect(restoredTask.state, DownloadTaskState.failed);
      expect(restoredTask.revision, 3);
      expect(restoredTask.bytesReceived, 120);
      expect(
        restoredTask.failure!.kind,
        DownloadFailureKind.insufficientStorage,
      );
      expect(restoredTask.failure!.requiredBytes, 380);
      expect(repository.copyById('cache-c1')!.hasTranslation, isFalse);
      expect(
        repository.readingProgressFor('novel')!.position,
        isA<ReadingPosition>(),
      );
      expect(repository.listBookmarks().single.id, 'bookmark-1');
      expect(repository.lastRoute()!.position!.blockId, 'block-7');
      expect(repository.recentSearches(), ['齿轮图书馆', '雪春']);
      expect(
        repository.appSettings()!.readerSettings.readingMode,
        ReadingMode.chineseOnly,
      );
      expect(
        repository.appSettings()!.readerSettings.layoutMode,
        ReaderLayoutMode.pages,
      );
      expect(
        repository.appSettings()!.readerSettings.palette,
        ReaderPalette.sepia,
      );
      expect(
        repository.appSettings()!.readerSettings.textSelectionEnabled,
        isFalse,
      );
      expect(
        repository.appSettings()!.readerSettings.tapPageTurnEnabled,
        isFalse,
      );
      expect(repository.appSettings()!.cacheLimitBytes, 64 * 1024 * 1024);
      expect(repository.passesIntegrityCheck, isTrue);
    });

    test(
      'ongoing reconciliation is source-scoped and queues future chapters',
      () {
        final repository = SqliteOfflineRepository.openInMemory();
        addTearDown(repository.close);
        repository.saveIntent(_novelIntent(t0));

        expect(
          repository.reconcileIntent(
            intentId: 'intent',
            knownChapterIds: ['c1', 'c2', 'c2'],
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

    test('commits matching task and copy in one transaction', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.saveIntent(_novelIntent(t0));
      var task = repository
          .reconcileIntent(intentId: 'intent', knownChapterIds: ['c1'], now: t0)
          .single;
      task = task.beginFetching(t0.add(const Duration(seconds: 1)));
      repository.saveTask(task);
      task = task.beginValidation(t0.add(const Duration(seconds: 2)));
      repository.saveTask(task);
      task = task.beginStoring(t0.add(const Duration(seconds: 3)));
      repository.saveTask(task);
      final copy = _downloadCopy(
        id: 'download-c1',
        chapterId: 'c1',
        storedAt: t0.add(const Duration(seconds: 4)),
      );

      repository.commitStoredTask(
        taskId: task.id,
        copy: copy,
        now: t0.add(const Duration(seconds: 4)),
      );

      expect(repository.taskById(task.id)!.state, DownloadTaskState.stored);
      expect(repository.taskById(task.id)!.storedCopyId, copy.id);
      expect(repository.copyById(copy.id)!.revision, 'r2');
      expect(repository.storageSummary().offlineDownloadBytes, 240);
    });

    test('mismatched atomic commit rolls back both records', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.saveIntent(_novelIntent(t0));
      var task = repository
          .reconcileIntent(intentId: 'intent', knownChapterIds: ['c1'], now: t0)
          .single;
      task = task.beginFetching(t0);
      repository.saveTask(task);
      task = task.beginValidation(t0);
      repository.saveTask(task);
      task = task.beginStoring(t0);
      repository.saveTask(task);
      final wrongCopy = _downloadCopy(
        id: 'wrong',
        chapterId: 'c2',
        storedAt: t0,
      );

      expect(
        () => repository.commitStoredTask(
          taskId: task.id,
          copy: wrongCopy,
          now: t0,
        ),
        throwsStateError,
      );
      expect(repository.copyById('wrong'), isNull);
      expect(repository.taskById(task.id)!.state, DownloadTaskState.storing);
    });

    test(
      'pause, resume, and stale revision behavior remains deterministic',
      () {
        final repository = SqliteOfflineRepository.openInMemory();
        addTearDown(repository.close);
        repository.saveIntent(_novelIntent(t0));
        final initial = repository
            .reconcileIntent(
              intentId: 'intent',
              knownChapterIds: ['c1'],
              now: t0,
            )
            .single;

        repository.pauseIntent('intent', t0.add(const Duration(seconds: 1)));
        expect(repository.intentById('intent')!.enabled, isFalse);
        expect(
          repository.taskById(initial.id)!.state,
          DownloadTaskState.paused,
        );
        repository.resumeIntent('intent', t0.add(const Duration(seconds: 2)));
        expect(
          repository.taskById(initial.id)!.state,
          DownloadTaskState.queued,
        );

        expect(
          () => repository.saveTask(
            initial.beginFetching(t0.add(const Duration(seconds: 3))),
          ),
          throwsStateError,
        );
      },
    );

    test('cache eviction and intent removal never cross retention classes', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.saveIntent(_novelIntent(t0));
      _saveCacheCopy(repository, id: 'old', chapterId: 'c1', storedAt: t0);
      _saveCacheCopy(
        repository,
        id: 'protected',
        chapterId: 'c2',
        storedAt: t0.add(const Duration(minutes: 1)),
      );
      _storeDownloadCopy(repository, t0);

      final evicted = repository.evictCacheTo(
        maxBytes: 200,
        protectedChapters: {
          const ChapterRef(novelId: 'novel', chapterId: 'c2'),
        },
      );
      expect(evicted.map((copy) => copy.id), ['old']);
      expect(repository.copyById('download'), isNotNull);

      repository.removeIntent('intent', t0.add(const Duration(days: 1)));
      expect(repository.copyById('download'), isNull);
      expect(repository.copyById('protected'), isNotNull);
    });
  });

  group('local reader state', () {
    test('orders progress and bookmarks deterministically', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: 'older',
          position: const ReadingPosition(chapterId: 'c1', blockId: 'b1'),
          updatedAt: t0,
        ),
      );
      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: 'newer',
          position: const ReadingPosition(chapterId: 'c2', blockId: 'b2'),
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      repository.saveBookmark(
        LocalBookmark(
          id: 'b1',
          novelId: 'newer',
          position: const ReadingPosition(chapterId: 'c2', blockId: 'p1'),
          createdAt: t0,
        ),
      );

      expect(repository.listReadingProgress().first.novelId, 'newer');
      expect(repository.listBookmarks(novelId: 'newer'), hasLength(1));
      repository.removeBookmark('b1');
      expect(repository.readingProgressFor('older'), isNotNull);
      expect(repository.listBookmarks(novelId: 'newer'), isEmpty);
    });

    test('stores top-level and reader route restoration states', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.saveLastRoute(
        LastRouteState(routeName: '/library', updatedAt: t0),
      );
      expect(repository.lastRoute()!.novelId, isNull);

      repository.saveLastRoute(
        LastRouteState(
          routeName: '/reader',
          novelId: 'novel',
          position: const ReadingPosition(
            chapterId: 'c3',
            blockId: 'b8',
            intraBlockOffset: 2,
          ),
          updatedAt: t0.add(const Duration(seconds: 1)),
        ),
      );
      expect(repository.lastRoute()!.position!.intraBlockOffset, 2);
    });

    test('normalizes, bounds, orders, and clears recent searches', () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);

      repository.saveRecentSearches([
        '  齿轮图书馆  ',
        '',
        '雪春',
        '齿轮图书馆',
        '三',
        '四',
        '五',
        '六',
        '七',
        '八',
        '九',
      ]);

      expect(repository.recentSearches(), [
        '齿轮图书馆',
        '雪春',
        '三',
        '四',
        '五',
        '六',
        '七',
        '八',
      ]);
      repository.saveRecentSearches(const []);
      expect(repository.recentSearches(), isEmpty);
    });
  });
}

NovelDownloadIntent _novelIntent(DateTime now) {
  return NovelDownloadIntent(
    id: 'intent',
    novelId: 'novel',
    translationSource: TranslationSource.sakura,
    createdAt: now,
  );
}

void _saveCacheCopy(
  SqliteOfflineRepository repository, {
  required String id,
  required String chapterId,
  required DateTime storedAt,
  int? translationBytes = 80,
}) {
  final payload = CachedChapterPayload(
    id: 'payload-$id',
    novelId: 'novel',
    chapterId: chapterId,
    index: 1,
    chineseTitle: '',
    japaneseTitle: '',
    previousChapterId: null,
    nextChapterId: null,
    publishedAt: null,
    japaneseBlocks: const ['原文'],
    translations: {
      TranslationSource.sakura: CachedChapterTranslation(
        availability: translationBytes == null
            ? TranslationAvailability.pending
            : TranslationAvailability.complete,
        blocks: translationBytes == null ? const [] : const ['译文'],
      ),
    },
    fetchedAt: storedAt,
    revision: 'r1',
  );
  repository.cacheChapterPayload(
    payload: payload,
    copy: OfflineChapterCopy(
      id: id,
      novelId: 'novel',
      chapterId: chapterId,
      kind: OfflineCopyKind.cacheCopy,
      translationSource: TranslationSource.sakura,
      originalBytes: 120,
      translationBytes: translationBytes,
      storedAt: storedAt,
      payloadId: payload.id,
      revision: payload.revision,
    ),
  );
}

void _storeDownloadCopy(SqliteOfflineRepository repository, DateTime storedAt) {
  var task = repository
      .reconcileIntent(
        intentId: 'intent',
        knownChapterIds: const ['c3'],
        now: storedAt,
      )
      .single;
  task = task.beginFetching(storedAt);
  repository.saveTask(task);
  task = task.beginValidation(storedAt);
  repository.saveTask(task);
  task = task.beginStoring(storedAt);
  repository.saveTask(task);
  repository.commitStoredTask(
    taskId: task.id,
    copy: _downloadCopy(id: 'download', chapterId: 'c3', storedAt: storedAt),
    now: storedAt,
  );
}

OfflineChapterCopy _downloadCopy({
  required String id,
  required String chapterId,
  required DateTime storedAt,
}) {
  return OfflineChapterCopy(
    id: id,
    novelId: 'novel',
    chapterId: chapterId,
    kind: OfflineCopyKind.offlineDownload,
    translationSource: TranslationSource.sakura,
    originalBytes: 140,
    translationBytes: 100,
    storedAt: storedAt,
    intentId: 'intent',
    revision: 'r2',
    etag: 'etag-r2',
  );
}

void _saveLocalState(SqliteOfflineRepository repository, DateTime now) {
  repository.saveReadingProgress(
    LocalReadingProgress(
      novelId: 'novel',
      position: const ReadingPosition(
        chapterId: 'c2',
        blockId: 'block-7',
        intraBlockOffset: 3,
      ),
      updatedAt: now,
    ),
  );
  repository.saveBookmark(
    LocalBookmark(
      id: 'bookmark-1',
      novelId: 'novel',
      position: const ReadingPosition(chapterId: 'c2', blockId: 'block-7'),
      createdAt: now,
    ),
  );
  repository.saveLastRoute(
    LastRouteState(
      routeName: '/reader',
      novelId: 'novel',
      position: const ReadingPosition(
        chapterId: 'c2',
        blockId: 'block-7',
        intraBlockOffset: 3,
      ),
      updatedAt: now,
    ),
  );
  repository.saveAppSettings(
    LocalAppSettings(
      readerSettings: const ReaderSettings(
        readingMode: ReadingMode.chineseOnly,
        translationSource: TranslationSource.gpt,
        layoutMode: ReaderLayoutMode.pages,
        palette: ReaderPalette.sepia,
        fontFamily: ReaderFontFamily.systemSerif,
        bodyBold: true,
        chineseFontSize: 24,
        japaneseFontSize: 15,
        lineHeight: 1.7,
        paragraphSpacing: 18,
        japaneseOpacity: 0.5,
        pageMargin: 30,
        readingWidth: 680,
        columnLayout: ReaderColumnLayout.singleColumn,
        orientationPreference: ReaderOrientationPreference.portrait,
        textSelectionEnabled: false,
        tapPageTurnEnabled: false,
      ),
      themePreference: ThemePreference.dark,
      cacheLimitBytes: 64 * 1024 * 1024,
      updatedAt: now,
    ),
  );
  repository.saveRecentSearches(['齿轮图书馆', '雪春']);
}

void _createVersion5SettingsFixture(Database database, DateTime now) {
  database.execute('''
    CREATE TABLE app_settings (
      singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
      reading_mode TEXT NOT NULL,
      translation_source TEXT NOT NULL,
      chinese_font_size REAL NOT NULL,
      japanese_font_size REAL NOT NULL,
      line_height REAL NOT NULL,
      japanese_opacity REAL NOT NULL,
      reading_width REAL NOT NULL,
      theme_preference TEXT NOT NULL,
      notify_new_chapters INTEGER NOT NULL CHECK (notify_new_chapters IN (0, 1)),
      cache_limit_bytes INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL
    );
  ''');
  database.execute(
    'INSERT INTO app_settings VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      ReadingMode.chineseOnly.name,
      TranslationSource.gpt.name,
      24.0,
      15.0,
      1.7,
      0.5,
      680.0,
      ThemePreference.dark.name,
      1,
      64 * 1024 * 1024,
      now.microsecondsSinceEpoch,
    ],
  );
  database.userVersion = 5;
}

void _createVersion1Fixture(Database database, DateTime now) {
  database.execute('''
    CREATE TABLE download_intents (
      id TEXT NOT NULL PRIMARY KEY,
      novel_id TEXT NOT NULL,
      intent_kind TEXT NOT NULL,
      chapter_id TEXT,
      translation_source TEXT NOT NULL,
      created_at_us INTEGER NOT NULL,
      enabled INTEGER NOT NULL
    );
    CREATE TABLE download_tasks (
      id TEXT NOT NULL PRIMARY KEY,
      intent_id TEXT NOT NULL,
      novel_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      translation_source TEXT NOT NULL,
      state TEXT NOT NULL,
      created_at_us INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL,
      task_revision INTEGER NOT NULL,
      attempt_count INTEGER NOT NULL,
      bytes_received INTEGER NOT NULL,
      total_bytes INTEGER,
      failure_kind TEXT,
      failure_message TEXT,
      failure_retryable INTEGER,
      failure_required_bytes INTEGER,
      failure_available_bytes INTEGER,
      stored_copy_id TEXT
    );
    CREATE TABLE offline_chapter_copies (
      id TEXT NOT NULL PRIMARY KEY,
      novel_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      copy_kind TEXT NOT NULL,
      translation_source TEXT NOT NULL,
      original_bytes INTEGER NOT NULL,
      translation_bytes INTEGER,
      stored_at_us INTEGER NOT NULL,
      last_read_at_us INTEGER NOT NULL,
      intent_id TEXT,
      chapter_revision TEXT,
      etag TEXT
    );
  ''');
  database.execute(
    'INSERT INTO download_intents VALUES (?, ?, ?, ?, ?, ?, ?);',
    [
      'legacy-intent',
      'legacy-novel',
      'novel',
      null,
      'gpt',
      now.microsecondsSinceEpoch,
      1,
    ],
  );
  database.execute(
    'INSERT INTO offline_chapter_copies VALUES '
    '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      'legacy-copy',
      'legacy-novel',
      'c1',
      'offlineDownload',
      'gpt',
      100,
      null,
      now.microsecondsSinceEpoch,
      now.microsecondsSinceEpoch,
      'legacy-intent',
      'r1',
      null,
    ],
  );
  database.userVersion = 1;
}
