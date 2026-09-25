import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/app_database.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';

import 'support/offline_library_fixture.dart';

void main() {
  const id = 'syosetu/offline-0';
  test(
    'unchanged TOC refresh updates book metadata without rewriting chapters',
    () {
      final database = NoveliaDatabase.openInMemory();
      final repository = SqliteOfflineRepository.fromDatabase(
        database,
        closeOnDispose: true,
      );
      addTearDown(repository.close);
      seedOfflineLibrary(repository);
      final saved = repository.novelDetail(id)!;
      for (final table in ['cached_toc_sections', 'cached_toc_chapters']) {
        for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
          database.execute(
            'CREATE TEMP TRIGGER forbid_${table}_$operation '
            'BEFORE $operation ON $table BEGIN '
            "SELECT RAISE(ABORT, 'unchanged TOC was rewritten'); END;",
          );
        }
      }
      repository.upsertNovelDetail(
        CachedNovelDetail(
          outline: saved.outline,
          synopsis: 'Updated synopsis',
          points: 123,
          views: 456,
          originalUrl: 'https://example.com/updated',
          sections: saved.sections,
        ),
      );
      final refreshed = repository.novelDetail(id)!;
      expect(refreshed.synopsis, 'Updated synopsis');
      expect(refreshed.points, 123);
      expect(refreshed.views, 456);
      expect(refreshed.originalUrl, 'https://example.com/updated');
      expect(repository.chapterLocation(id, 'c2')!.ordinal, 1);
    },
  );

  test(
    'lightweight shelf stays current across progress, pause, TOC edits and removal',
    () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      seedOfflineLibrary(repository);
      LocalLibrarySnapshot shelf() =>
          LocalLibrarySnapshot.load(repository, knownNovels: const []);
      final before = shelf();
      expect(before.continuedReads.length, 43);
      expect(before.downloads.length, 42);
      expect(before.downloads.every((d) => !d.novel.hasChapterCatalog), isTrue);
      expect(
        before.continuedReads.firstWhere((r) => r.novel.id == id).progress,
        1,
      );
      final now = DateTime.utc(2026, 9, 25);
      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: id,
          position: const ReadingPosition(chapterId: 'c1', blockId: 'c1:0'),
          updatedAt: now,
        ),
      );
      repository.pauseIntent('intent-0', now);
      final after = shelf();
      expect(after.continuedReads.first.novel.id, id);
      expect(after.continuedReads.first.progress, .25);
      expect(after.continuedReads.first.chapterLabel, '第1章');
      expect(
        after.downloads.firstWhere((d) => d.novel.id == id).enabled,
        isFalse,
      );
      final saved = repository.novelDetail(id)!;
      repository.upsertNovelDetail(
        CachedNovelDetail(
          outline: saved.outline,
          synopsis: saved.synopsis,
          points: null,
          views: null,
          originalUrl: null,
          sections: [
            CachedTocSection(id: 'empty', title: '空卷', chapters: const []),
            CachedTocSection(
              id: 'new',
              title: '新卷',
              chapters: [
                CachedTocChapter(
                  id: 'new',
                  index: 50,
                  chineseTitle: '新章',
                  japaneseTitle: '',
                ),
                CachedTocChapter(
                  id: 'c1',
                  index: 20,
                  chineseTitle: '',
                  japaneseTitle: '改題',
                  publishedAt: now,
                ),
              ],
            ),
          ],
        ),
      );
      // Ordinals follow section order, not source indices. c2 remains local.
      expect(repository.chapterLocation(id, 'c1')!.ordinal, 1);
      expect(repository.chapterLocation(id, 'c2')!.ordinal, 2);
      expect(repository.chapterLocation(id, 'c2')!.chapterCount, 3);
      expect(repository.chapterLocation(id, 'missing'), isNull);
      expect(repository.chapterOrder(id, ['c2', 'c1', 'new', 'missing']).keys, [
        'new',
        'c1',
        'c2',
      ]);
      final edited = shelf();
      expect(edited.continuedReads.first.chapterLabel, '改題');
      expect(edited.continuedReads.first.progress, .5);
      expect(
        edited.bookmarks.firstWhere((b) => b.novel.id == id).chapterLabel,
        '第2章',
      );
      repository.removeIntent('intent-0', now);
      expect(shelf().downloads.any((d) => d.novel.id == id), isFalse);
      expect(repository.chapterLocation(id, 'c2'), isNull);
      expect(shelf().continuedReads.first.position.chapterId, 'c1');
    },
  );

  test(
    'download ordering spans parameter batches and reflects chapter reordering',
    () {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      seedOfflineLibrary(repository);
      final saved = repository.novelDetail(id)!;
      CachedNovelDetail detail(Iterable<int> indices) => CachedNovelDetail(
        outline: saved.outline,
        synopsis: '',
        points: null,
        views: null,
        originalUrl: null,
        sections: [
          CachedTocSection(
            id: 'large',
            title: 'Large TOC',
            chapters: [
              for (final i in indices)
                CachedTocChapter(
                  id: 'large-$i',
                  index: i,
                  chineseTitle: '$i',
                  japaneseTitle: '$i',
                ),
            ],
          ),
        ],
      );
      final ids = List.generate(1200, (i) => i);
      repository.upsertNovelDetail(detail(ids));
      expect(
        repository.chapterOrder(id, ids.reversed.map((i) => 'large-$i')).keys,
        ids.map((i) => 'large-$i'),
      );
      repository.upsertNovelDetail(detail(ids.reversed));
      expect(
        repository.chapterOrder(id, ids.map((i) => 'large-$i')).keys,
        ids.reversed.map((i) => 'large-$i'),
      );
      expect(repository.passesIntegrityCheck, isTrue);
    },
  );
}
