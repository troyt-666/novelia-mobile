import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/gateway/novelia/novelia_reader_cache.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/offline_library_fixture.dart';

// Observe where the input is consumed without passing a SQLite handle or a
// closure over one through an isolate message.
class _ObservedNovels extends ListBase<CatalogNovel> {
  _ObservedNovels(this.report);
  final SendPort report;
  @override
  int get length => 1;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  CatalogNovel operator [](int index) {
    report.send(Isolate.current.hashCode);
    return fixtureCatalogNovels.first;
  }

  @override
  void operator []=(int index, CatalogNovel value) =>
      throw UnsupportedError('read only');
}

void main() {
  test(
    'background chapter reader preserves protected/cache distinction and corruption handling',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'reader-cache-worker-',
      );
      final path = '${directory.path}/reader.sqlite';
      final repository = SqliteOfflineRepository.openFile(path);
      try {
        seedOfflineLibrary(repository);
        final downloaded = await BackgroundReaderCache.load(
          path,
          'syosetu/offline-0',
          'c1',
          TranslationSource.sakura,
        );
        expect(downloaded.downloaded, isTrue);
        expect(downloaded.chapter!.blocks, isNotEmpty);
        final cached = await BackgroundReaderCache.load(
          path,
          'syosetu/offline-42',
          'c1',
          TranslationSource.sakura,
        );
        expect(cached.downloaded, isFalse);
        expect(cached.chapter!.blocks, isNotEmpty);
        final missing = await BackgroundReaderCache.load(
          path,
          'syosetu/offline-0',
          'missing',
          TranslationSource.sakura,
        );
        expect(missing.chapter, isNull);
        final raw = sqlite3.open(path);
        try {
          raw.execute(
            "UPDATE cached_chapter_payloads SET japanese_blocks_json = 'broken' WHERE chapter_id = 'c1';",
          );
        } finally {
          raw.close();
        }
        final corruptCache = await BackgroundReaderCache.load(
          path,
          'syosetu/offline-42',
          'c1',
          TranslationSource.sakura,
        );
        expect(corruptCache.chapter, isNull);
        await expectLater(
          BackgroundReaderCache.load(
            path,
            'syosetu/offline-0',
            'c1',
            TranslationSource.sakura,
          ),
          throwsStateError,
        );
      } finally {
        repository.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'worker reads the live WAL and returns the complete offline shelf',
    () async {
      final directory = Directory.systemTemp.createTempSync('library-worker-');
      final repository = SqliteOfflineRepository.openFile(
        '${directory.path}/reader.sqlite',
      );
      final reports = ReceivePort();
      try {
        seedOfflineLibrary(repository);
        final expected = LocalLibrarySnapshot.load(repository, knownNovels: []);
        final observed = reports.first;
        final actual = await LocalLibrarySnapshot.loadInBackground(
          repository.databasePath!,
          knownNovels: _ObservedNovels(reports.sendPort),
        );
        expect(await observed, isNot(Isolate.current.hashCode));
        expect(actual.novelIds, expected.novelIds);
        expect(
          actual.continuedReads.map((row) => (row.novel.id, row.position)),
          expected.continuedReads.map((row) => (row.novel.id, row.position)),
        );
        expect(
          actual.bookmarks.map((row) => row.id),
          expected.bookmarks.map((row) => row.id),
        );
        expect(
          actual.downloads.map((row) => (row.groupKey, row.chapters.length)),
          expected.downloads.map((row) => (row.groupKey, row.chapters.length)),
        );
        expect(
          actual.storageSummary.offlineDownloadBytes,
          expected.storageSummary.offlineDownloadBytes,
        );
        repository.removeIntent('intent-0', DateTime.utc(2026, 11));
        final updated = await LocalLibrarySnapshot.loadInBackground(
          repository.databasePath!,
        );
        expect(updated.downloads.length, expected.downloads.length - 1);
      } finally {
        reports.close();
        repository.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'read snapshot is consistent across concurrent commits and cannot write',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'library-snapshot-',
      );
      final writer = SqliteOfflineRepository.openFile(
        '${directory.path}/reader.sqlite',
      );
      LocalReadingProgress progress(int block) => LocalReadingProgress(
        novelId: 'fixture',
        position: ReadingPosition(chapterId: 'c1', blockId: 'c1:$block'),
        updatedAt: DateTime.utc(2026, 1, block + 1),
      );
      try {
        writer.saveReadingProgress(progress(0));
        final reader = SqliteOfflineRepository.openReadSnapshot(
          writer.databasePath!,
        );
        try {
          expect(
            reader.readingProgressFor('fixture')!.position.blockId,
            'c1:0',
          );
          writer.saveReadingProgress(progress(1));
          expect(
            reader.readingProgressFor('fixture')!.position.blockId,
            'c1:0',
          );
          expect(
            () => reader.saveReadingProgress(progress(2)),
            throwsA(isA<Exception>()),
          );
        } finally {
          reader.close();
        }
        final latest = SqliteOfflineRepository.openReadSnapshot(
          writer.databasePath!,
        );
        try {
          expect(
            latest.readingProgressFor('fixture')!.position.blockId,
            'c1:1',
          );
        } finally {
          latest.close();
        }
        expect(writer.passesIntegrityCheck, isTrue);
      } finally {
        writer.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
