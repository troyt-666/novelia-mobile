import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_reader_window.dart';
import 'package:jfzreader/main.dart';

import 'support/offline_library_fixture.dart';
import 'support/backup_fixture.dart';

void main() {
  late SqliteOfflineRepository repository;
  late OfflineLibraryGateway gateway;
  const adapter = NoveliaContentCacheAdapter();
  const novelId = 'syosetu/offline-0';
  setUp(() {
    repository = SqliteOfflineRepository.openInMemory();
    seedOfflineLibrary(repository);
    gateway = _PendingGateway();
  });
  tearDown(() => repository.close());

  test(
    'downloaded reading uses its translation snapshot, never newer temporary text or a network refresh',
    () async {
      final saved = repository.chapterPayload(
        novelId: novelId,
        chapterId: 'c2',
      )!;
      final newer = CachedChapterPayload(
        id: 'newer-temporary',
        novelId: novelId,
        chapterId: 'c2',
        index: 1,
        chineseTitle: saved.chineseTitle,
        japaneseTitle: saved.japaneseTitle,
        previousChapterId: 'c1',
        nextChapterId: null,
        publishedAt: saved.publishedAt,
        japaneseBlocks: const ['変更後の本文'],
        translations: {
          TranslationSource.gpt: CachedChapterTranslation(
            availability: TranslationAvailability.complete,
            blocks: const ['较新的临时 GPT 正文'],
          ),
        },
        fetchedAt: saved.fetchedAt.add(const Duration(days: 1)),
      );
      repository.cacheChapterPayload(
        payload: newer,
        copy: adapter.cacheCopy(
          newer,
          translationSource: TranslationSource.gpt,
          storedAt: newer.fetchedAt,
        ),
      );
      final novel = adapter.restoreDetails(repository.novelDetail(novelId)!);
      final launch =
          await NoveliaReaderWindowFactory(
            contentCoordinator: LiveFirstNoveliaContentCoordinator(
              gateway: gateway,
              contentRepository: repository,
            ),
          ).create(
            novel: novel,
            selectedChapter: null,
            requestedPosition: offlineLatestPosition,
            translationSource: TranslationSource.sakura,
          );
      final read = launch.novel.chapters.singleWhere(
        (chapter) => chapter.id == 'c2',
      );
      expect(read.blocks.first.japanese, saved.japaneseBlocks.first);
      expect(
        read.blocks.first.translations[TranslationSource.sakura],
        '已经下载的故事。',
      );
      await Future<void>.delayed(Duration.zero);
      expect(gateway.contentRequests, 0);
      seedBackupDownload(
        repository,
        novelId: novelId,
        chapter: 'c2',
        intentId: 'gpt-download',
        payloadId: 'gpt-protected',
        copyId: 'gpt-copy',
        source: TranslationSource.gpt,
        text: '另存的 GPT 下载',
      );
      NovelChapter? switched;
      launch.dataSource!.addChapterUpdateListener((chapter) {
        if (chapter.id == 'c2') switched = chapter;
      });
      launch.dataSource!.onTranslationSourceChanged!(TranslationSource.gpt);
      expect(
        switched!.blocks.first.translations[TranslationSource.gpt],
        '另存的 GPT 下载',
      );
      expect(gateway.contentRequests, 0);
    },
  );

  test(
    'a removed remote chapter remains in downloads, continue reading and bookmarks with its local body',
    () async {
      final previous = repository.novelDetail(novelId)!;
      final shortened = CachedNovelDetail(
        outline: previous.outline,
        synopsis: previous.synopsis,
        points: previous.points,
        views: previous.views,
        originalUrl: previous.originalUrl,
        sections: [
          CachedTocSection(
            id: 'body',
            title: '正文',
            chapters: [previous.sections.single.chapters.first],
          ),
        ],
      );
      repository.upsertNovelDetail(shortened);
      final live = adapter.restoreDetails(shortened);
      final shelf = LocalLibrarySnapshot.load(repository, knownNovels: [live]);
      final download = shelf.downloads.firstWhere(
        (item) => item.novel.id == novelId,
      );
      expect(
        download.chapters.map((chapter) => chapter.chapterId),
        contains('c2'),
      );
      // Shelf rows stay lightweight; opening the book hydrates only this TOC.
      final novel = adapter.restoreDetails(
        repository.novelDetail(download.novel.id)!,
      );
      expect(
        novel.readerNovel!.chapters.map((chapter) => chapter.id),
        contains('c2'),
      );
      expect(
        shelf.continuedReads
            .firstWhere((item) => item.novel.id == novelId)
            .position,
        offlineLatestPosition,
      );
      expect(
        shelf.bookmarks.firstWhere((item) => item.novel.id == novelId).position,
        offlineLatestPosition,
      );
      expect(
        shelf.bookmarks
            .firstWhere((item) => item.novel.id == novelId)
            .chapterLabel,
        '第2章',
      );
      expect(
        shelf.continuedReads
            .firstWhere((item) => item.novel.id == novelId)
            .progress,
        1,
      );
      final launch =
          await NoveliaReaderWindowFactory(
            contentCoordinator: LiveFirstNoveliaContentCoordinator(
              gateway: gateway,
              contentRepository: repository,
            ),
          ).create(
            novel: novel,
            selectedChapter: null,
            requestedPosition: offlineLatestPosition,
            translationSource: TranslationSource.sakura,
          );
      expect(launch.initialPosition, offlineLatestPosition);
      expect(
        launch.novel.chapters
            .singleWhere((chapter) => chapter.id == 'c2')
            .blocks,
        isNotEmpty,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gateway.contentRequests, 0);
    },
  );

  testWidgets(
    'saved book details open without waiting for an unreachable website',
    (tester) async {
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: LiveFirstNoveliaContentCoordinator(
            gateway: gateway,
            contentRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shell = tester.widget<NoveliaShell>(find.byType(NoveliaShell));
      final outline = adapter.restoreOutline(
        repository.cachedNovelOutline(novelId)!,
      );
      var opened = false;
      unawaited(
        shell.novelDetailsLoader!(outline).then((novel) {
          expectSync(novel.readerNovel!.chapters, hasLength(2));
          opened = true;
        }),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened, isTrue);
      // Metadata can refresh in the background; its hanging response must not
      // block the local detail page.
      expect(gateway.contentRequests, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _PendingGateway extends OfflineLibraryGateway {
  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) {
    contentRequests++;
    return Completer<NoveliaNovelDetails>().future;
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId, {
    void Function(int, int?)? onReceiveProgress,
  }) {
    contentRequests++;
    return Completer<NoveliaChapterPayload>().future;
  }
}
