import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/backup_fixture.dart';

void main() {
  late SqliteOfflineRepository local, incoming;
  setUp(() {
    local = SqliteOfflineRepository.openInMemory();
    incoming = SqliteOfflineRepository.openInMemory();
  });
  tearDown(() {
    local.close();
    incoming.close();
  });

  test(
    'portable file roundtrip; default excludes content, transient and account state',
    () async {
      seedBackupNovel(incoming);
      seedBackupProgress(incoming);
      seedBackupBookmark(incoming);
      seedBackupDownload(incoming);
      seedBackupDownload(
        incoming,
        chapter: 'c2',
        payloadId: 'cache',
        copyId: 'cache',
        cacheOnly: true,
      );
      incoming.saveLastRoute(
        LastRouteState(
          routeName: '/reader',
          novelId: backupNovelId,
          position: incoming.readingProgressFor(backupNovelId)!.position,
          updatedAt: backupTime,
        ),
      );
      final backup = incoming.exportBackup(now: backupTime);
      expect(backup.chapterCount, 0);
      expect(backup.downloadCount, 1);
      expect(backup.tables.keys, isNot(contains('last_route_state')));
      expect(backup.tables.keys, isNot(contains('remote_history_outbox')));
      expect(backup.tables.keys, isNot(contains('download_tasks')));
      final directory = await Directory.systemTemp.createTemp('backup-test-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/export.jfzbackup');
      await file.writeAsBytes(backup.encode());
      final decoded = await ReaderBackup.readFile(file.path);
      final preview = local.previewBackup(decoded);
      expect(preview.newDownloads, 1);
      expect(
        local.listReadingProgress(),
        isEmpty,
        reason: 'preview must not write',
      );
      local.mergeBackup(preview);
      expect(
        local.readingProgressFor(backupNovelId)!.position,
        incoming.readingProgressFor(backupNovelId)!.position,
      );
      expect(local.listBookmarks(), hasLength(1));
      expect(local.listTasks(), hasLength(3));
      expect(
        local.listTasks().every((t) => t.state == DownloadTaskState.paused),
        isTrue,
      );
      expect(local.listIntents().single.enabled, isFalse);
      expect(local.lastRoute(), isNull);
      expect(
        incoming.exportBackup(includeContent: true).chapterCount,
        1,
        reason: 'cache is excluded',
      );
      expect(local.passesIntegrityCheck, isTrue);
    },
  );

  test(
    'newer backtracking wins; losing location is bookmarked; repeat is idempotent',
    () {
      seedBackupNovel(local);
      seedBackupNovel(incoming);
      seedBackupProgress(local, chapter: 'c3');
      seedBackupProgress(
        incoming,
        chapter: 'c1',
        time: backupTime.add(const Duration(hours: 2)),
      );
      final backup = incoming.exportBackup();
      final preview = local.previewBackup(backup);
      expect(preview.conflicts.single.recommended, ProgressChoice.imported);
      local.mergeBackup(preview);
      expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c1');
      expect(local.listBookmarks().single.position.chapterId, 'c3');
      final again = local.mergeBackup(local.previewBackup(backup));
      expect(again.progressUpdated, 0);
      expect(again.bookmarksAdded, 0);
      expect(local.listBookmarks(), hasLength(1));
    },
  );

  test(
    'same time keeps local and explicit choice can override newer default',
    () {
      seedBackupProgress(local, chapter: 'c1');
      seedBackupProgress(incoming, chapter: 'c3');
      var preview = local.previewBackup(incoming.exportBackup());
      expect(preview.conflicts.single.recommended, ProgressChoice.local);
      local.mergeBackup(preview);
      expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c1');
      seedBackupProgress(
        incoming,
        chapter: 'c2',
        time: backupTime.add(const Duration(days: 1)),
      );
      preview = local.previewBackup(incoming.exportBackup());
      local.mergeBackup(
        preview,
        choices: {backupNovelId: ProgressChoice.local},
      );
      expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c1');
      expect(
        local.listBookmarks().map((b) => b.position.chapterId),
        containsAll(['c2', 'c3']),
      );
    },
  );

  test(
    'same title is not identity; reused bookmark IDs cannot overwrite local rows',
    () {
      seedBackupNovel(local);
      seedBackupNovel(incoming, id: 'syosetu/n2000bk');
      seedBackupBookmark(local);
      seedBackupBookmark(incoming, novelId: 'syosetu/n2000bk');
      seedBackupBookmark(
        incoming,
        bookmarkId: 'same-position-other-id',
        novelId: 'syosetu/n2000bk',
      );
      local.mergeBackup(local.previewBackup(incoming.exportBackup()));
      expect(local.listCachedNovels(), hasLength(2));
      expect(local.listBookmarks(), hasLength(2));
      expect(local.listBookmarks().map((b) => b.id).toSet(), hasLength(2));
    },
  );

  test(
    'orphan records get a visible fallback title without modifying exporter',
    () {
      seedBackupProgress(incoming);
      final backup = incoming.exportBackup();
      expect(incoming.listCachedNovels(), isEmpty);
      local.mergeBackup(local.previewBackup(backup));
      expect(
        LocalLibrarySnapshot.load(local, knownNovels: []).continuedReads,
        hasLength(1),
      );
    },
  );

  test(
    'content merges by chapter and source, protecting local text and avoiding ID collisions',
    () {
      seedBackupNovel(local);
      seedBackupNovel(incoming);
      seedBackupDownload(local, text: '本机版本');
      seedBackupDownload(incoming, text: '另一个版本');
      seedBackupDownload(
        incoming,
        intentId: 'gpt-intent',
        payloadId: 'gpt-payload',
        copyId: 'gpt-copy',
        source: TranslationSource.gpt,
        text: '另一译源',
      );
      final backup = incoming.exportBackup(includeContent: true);
      expect(local.previewBackup(backup).newChapters, 1);
      local.mergeBackup(local.previewBackup(backup));
      expect(
        local
            .chapterPayloadById('payload')!
            .translations[TranslationSource.sakura]!
            .blocks,
        ['本机版本'],
      );
      final gpt = local.listCopies().singleWhere(
        (c) => c.translationSource == TranslationSource.gpt,
      );
      expect(
        local
            .chapterPayloadById(gpt.payloadId!)!
            .translations[TranslationSource.gpt]!
            .blocks,
        ['另一译源'],
      );
      expect(
        local.listIntents().singleWhere((i) => i.id == 'intent').enabled,
        isTrue,
      );
      expect(
        local.listIntents().singleWhere((i) => i.id == 'gpt-intent').enabled,
        isFalse,
      );
      final again = local.mergeBackup(local.previewBackup(backup));
      expect(again.chaptersAdded, 0);
      expect(local.listCopies(), hasLength(2));
      expect(local.passesIntegrityCheck, isTrue);
    },
  );

  test(
    'colliding intent, copy and payload IDs on different novels remain separate',
    () {
      seedBackupNovel(local);
      seedBackupNovel(incoming, id: 'syosetu/n2000bk');
      seedBackupDownload(local);
      seedBackupDownload(incoming, novelId: 'syosetu/n2000bk', text: '另一部小说');
      final backup = incoming.exportBackup(includeContent: true);
      local.mergeBackup(local.previewBackup(backup));
      expect(local.listIntents(), hasLength(2));
      expect(local.listCopies(), hasLength(2));
      expect(local.listCopies().map((c) => c.payloadId).toSet(), hasLength(2));
      local.mergeBackup(local.previewBackup(backup));
      expect(local.listIntents(), hasLength(2));
      expect(local.listCopies(), hasLength(2));
    },
  );

  test(
    'settings opt in, searches union, existing restore route stays local',
    () {
      for (final repo in [local, incoming]) {
        repo.saveAppSettings(
          LocalAppSettings(
            readerSettings: const ReaderSettings(),
            themePreference: identical(repo, local)
                ? ThemePreference.light
                : ThemePreference.dark,
            cacheLimitBytes: 100000,
            updatedAt: backupTime,
          ),
        );
      }
      local.saveRecentSearches(['本机', '共同']);
      incoming.saveRecentSearches(['备份', '共同']);
      local.saveLastRoute(
        LastRouteState(routeName: '/settings', updatedAt: backupTime),
      );
      final backup = incoming.exportBackup();
      local.mergeBackup(local.previewBackup(backup));
      expect(local.appSettings()!.themePreference, ThemePreference.light);
      expect(local.recentSearches(), ['本机', '共同', '备份']);
      expect(local.lastRoute()!.routeName, '/settings');
      local.mergeBackup(local.previewBackup(backup), importSettings: true);
      expect(local.appSettings()!.themePreference, ThemePreference.dark);
    },
  );

  test('stale preview rejects instead of replacing a newly read position', () {
    seedBackupProgress(incoming);
    final preview = local.previewBackup(incoming.exportBackup());
    seedBackupProgress(local, chapter: 'c3');
    expect(() => local.mergeBackup(preview), throwsA(isA<BackupException>()));
    expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c3');
    expect(local.listBookmarks(), isEmpty);
  });

  test(
    'write failure rolls back the entire batch, including newly added metadata',
    () {
      final db = sqlite3.openInMemory();
      final target = SqliteOfflineRepository.fromDatabase(db);
      addTearDown(() {
        target.close();
        db.close();
      });
      seedBackupNovel(incoming);
      seedBackupProgress(incoming);
      seedBackupBookmark(incoming);
      final preview = target.previewBackup(incoming.exportBackup());
      db.execute(
        "CREATE TRIGGER fail_progress BEFORE INSERT ON reading_progress BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END;",
      );
      expect(
        () => target.mergeBackup(preview),
        throwsA(isA<SqliteException>()),
      );
      expect(target.listCachedNovels(), isEmpty);
      expect(target.listBookmarks(), isEmpty);
      expect(target.listReadingProgress(), isEmpty);
      expect(target.passesIntegrityCheck, isTrue);
    },
  );

  test(
    'invalid rows, unknown tables and broken content references never mutate local data',
    () {
      seedBackupNovel(incoming);
      seedBackupProgress(incoming);
      seedBackupDownload(incoming);
      final source = incoming.exportBackup(includeContent: true);
      for (final table in [
        'reading_progress',
        'offline_chapter_copies',
        'app_settings',
      ]) {
        final tables = {
          for (final entry in source.tables.entries)
            entry.key: entry.value
                .map((r) => Map<String, Object?>.of(r))
                .toList(),
        };
        if (table == 'reading_progress') {
          tables[table]![0]['intra_block_offset'] = -1;
        }
        if (table == 'offline_chapter_copies') {
          tables[table]![0]['payload_id'] = 'missing';
        }
        if (table == 'app_settings') tables['arbitrary_sql'] = [];
        final bad = ReaderBackup(
          createdAt: backupTime,
          includesContent: true,
          tables: tables,
        );
        expect(() => local.previewBackup(bad), throwsA(isA<BackupException>()));
        expect(local.listCachedNovels(), isEmpty);
        expect(local.listReadingProgress(), isEmpty);
      }
    },
  );

  test(
    'truncated files and newer format are rejected before a preview',
    () async {
      final dir = await Directory.systemTemp.createTemp('backup-corrupt-');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = incoming.exportBackup().encode();
      final file = await File(
        '${dir.path}/bad',
      ).writeAsBytes(bytes.take(bytes.length - 10).toList());
      await expectLater(
        ReaderBackup.readFile(file.path),
        throwsA(isA<BackupException>()),
      );
      final data =
          jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
      data['version'] = 999;
      expect(
        () => ReaderBackup.fromJson(data),
        throwsA(isA<BackupException>()),
      );
      expect(local.listReadingProgress(), isEmpty);
    },
  );
}
