import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/app_database.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';

void main() {
  test('downloads follow latest download, reading and task activity', () {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final novels = fixtureCatalogNovels.take(3).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final now = DateTime.utc(2026, 9, 13);
    for (var i = 0; i < novels.length; i++) {
      repository.saveIntent(
        NovelDownloadIntent(
          id: 'intent-$i',
          novelId: novels[i].id,
          translationSource: TranslationSource.sakura,
          createdAt: now.add(Duration(minutes: i)),
        ),
      );
    }
    List<String> order() => LocalLibrarySnapshot.load(
      repository,
      knownNovels: novels,
      allowRestricted: false,
    ).downloads.map((row) => row.novel.id).toList();
    expect(order(), novels.reversed.map((novel) => novel.id).toList());
    repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: novels.first.id,
        position: const ReadingPosition(chapterId: 'c1', blockId: 'c1:0'),
        updatedAt: now.add(const Duration(minutes: 5)),
      ),
    );
    expect(order().first, novels.first.id);
    final task = DownloadTask.queued(
      id: 'task',
      intentId: 'intent-1',
      novelId: novels[1].id,
      chapterId: 'c1',
      translationSource: TranslationSource.sakura,
      now: now.add(const Duration(minutes: 6)),
    );
    repository.saveTask(task);
    repository.saveTask(task.pause(now.add(const Duration(minutes: 7))));
    expect(order().first, novels[1].id);
  });

  test(
    'shelf loads only referenced novels and applies current account access',
    () {
      final database = NoveliaDatabase.openInMemory();
      final repository = SqliteOfflineRepository.fromDatabase(
        database,
        closeOnDispose: true,
      );
      addTearDown(repository.close);
      final now = DateTime.utc(2026, 9, 6);
      CachedNovelOutline outline(String id, {bool restricted = false}) =>
          CachedNovelOutline(
            id: 'syosetu/$id',
            chineseTitle: id,
            japaneseTitle: id,
            author: '',
            contentSource: 'Syosetu',
            publicationState: CachedNovelState.ongoing,
            chapterCount: 1,
            wordCount: null,
            updatedAt: now,
            tags: [if (restricted) 'R18'],
            translationCoverage: const [],
            fetchedAt: now,
          );
      final general = outline('general');
      final restricted = outline('restricted', restricted: true);
      for (final novel in [general, restricted, outline('unrelated')]) {
        repository.upsertNovelOutline(novel);
      }
      // An unrelated bad catalog record must never be decoded by shelf loading.
      database.execute(
        "UPDATE cached_novels SET coverage_json = 'invalid JSON' WHERE id = 'syosetu/unrelated';",
      );
      for (final novel in [general, restricted]) {
        repository.saveReadingProgress(
          LocalReadingProgress(
            novelId: novel.id,
            position: const ReadingPosition(chapterId: 'c1', blockId: 'c1:0'),
            updatedAt: now,
          ),
        );
      }
      const adapter = NoveliaContentCacheAdapter();
      final known = [adapter.restoreOutline(restricted, allowRestricted: true)];
      final signedIn = LocalLibrarySnapshot.load(
        repository,
        knownNovels: known,
        allowRestricted: true,
      );
      expect(
        signedIn.continuedReads.map((row) => row.novel.id),
        containsAll([general.id, restricted.id]),
      );
      final signedOut = LocalLibrarySnapshot.load(
        repository,
        knownNovels: known,
        allowRestricted: false,
      );
      expect(signedOut.continuedReads.single.novel.id, general.id);
    },
  );
}
