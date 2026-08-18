import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_reader_window.dart';

void main() {
  test(
    'online download survives relaunch, reads offline, and refreshes pending',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'novelia-gateway-contract-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final databasePath = '${directory.path}/reader.sqlite3';
      final gateway = _StatefulNoveliaGateway();
      final epoch = DateTime.utc(2026, 8, 17, 12);
      var tick = 0;
      DateTime clock() => epoch.add(Duration(seconds: tick++));

      var repository = SqliteOfflineRepository.openFile(databasePath);
      addTearDown(repository.close);
      var content = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        clock: clock,
      );

      final onlineCatalog = await content.loadCatalog(
        const NoveliaCatalogQuery(),
      );
      final onlineDetails = await content.loadDetails(
        onlineCatalog.data!.novels.single,
      );
      repository.saveIntent(
        NovelDownloadIntent(
          id: 'novel-download',
          novelId: onlineDetails.data!.id,
          translationSource: TranslationSource.sakura,
          createdAt: clock(),
        ),
      );
      final downloader = AsyncNoveliaDownloadCoordinator(
        gateway: gateway,
        contentRepository: repository,
        offlineRepository: repository,
        clock: clock,
      );
      final firstDownload = await downloader.synchronizeIntent(
        'novel-download',
      );
      expect(
        firstDownload.tasks.every(
          (task) => task.state == DownloadTaskState.stored,
        ),
        isTrue,
      );

      const savedPosition = ReadingPosition(
        chapterId: 'c2',
        blockId: 'c2:1',
        intraBlockOffset: 0,
      );
      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: onlineDetails.data!.id,
          position: savedPosition,
          updatedAt: clock(),
        ),
      );
      repository.saveLastRoute(
        LastRouteState(
          routeName: '/reader',
          novelId: onlineDetails.data!.id,
          position: savedPosition,
          updatedAt: clock(),
        ),
      );
      repository.close();

      // A real file-backed reopen models process relaunch more strongly than
      // two unrelated in-memory handles.
      repository = SqliteOfflineRepository.openFile(databasePath);
      addTearDown(repository.close);
      gateway.online = false;
      content = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        clock: clock,
      );

      final cachedCatalog = await content.loadCatalog(
        const NoveliaCatalogQuery(),
      );
      expect(cachedCatalog.availability, CatalogAvailability.offline);
      expect(cachedCatalog.origin, NoveliaContentOrigin.cache);
      final cachedDetails = await content.loadDetails(
        cachedCatalog.data!.novels.single,
      );
      expect(cachedDetails.availability, CatalogAvailability.offline);
      expect(cachedDetails.origin, NoveliaContentOrigin.cache);

      final restoredPosition = repository
          .readingProgressFor(cachedDetails.data!.id)!
          .position;
      final launch =
          await NoveliaReaderWindowFactory(contentCoordinator: content).create(
            novel: cachedDetails.data!,
            selectedChapter: null,
            requestedPosition: restoredPosition,
            translationSource: TranslationSource.sakura,
          );
      expect(launch.initialPosition!.chapterId, savedPosition.chapterId);
      expect(launch.initialPosition!.blockId, savedPosition.blockId);
      final pendingChapter = launch.novel.chapters.singleWhere(
        (chapter) => chapter.id == savedPosition.chapterId,
      );
      expect(
        pendingChapter.blocks.any((block) => block.id == savedPosition.blockId),
        isTrue,
      );
      expect(
        pendingChapter.translationState(TranslationSource.sakura),
        TranslationState.pending,
      );

      final pendingTask = repository
          .listTasks(intentId: 'novel-download')
          .singleWhere((task) => task.chapterId == 'c2');
      final pendingCopy = repository.copyById(pendingTask.storedCopyId!)!;
      final pendingPayloadId = pendingCopy.payloadId!;
      final pendingTaskRevision = pendingTask.revision;

      gateway
        ..online = true
        ..secondChapterTranslated = true;
      final refreshed = await AsyncNoveliaDownloadCoordinator(
        gateway: gateway,
        contentRepository: repository,
        offlineRepository: repository,
        clock: clock,
      ).synchronizeIntent('novel-download');

      expect(refreshed.refreshedCopyCount, 1);
      final refreshedTask = repository.taskById(pendingTask.id)!;
      final refreshedCopy = repository.copyById(pendingCopy.id)!;
      expect(refreshedTask.state, DownloadTaskState.stored);
      expect(refreshedTask.revision, pendingTaskRevision);
      expect(refreshedTask.storedCopyId, pendingCopy.id);
      expect(refreshedCopy.id, pendingCopy.id);
      expect(refreshedCopy.payloadId, isNot(pendingPayloadId));
      expect(refreshedCopy.translationBytes, isNotNull);
      final refreshedPayload = repository.chapterPayloadById(
        refreshedCopy.payloadId!,
      )!;
      expect(
        refreshedPayload.translationFor(TranslationSource.sakura)!.availability,
        TranslationAvailability.complete,
      );
      final translatedChapter = const NoveliaContentCacheAdapter()
          .restoreChapter(refreshedPayload);
      expect(
        translatedChapter.translationState(TranslationSource.sakura),
        TranslationState.complete,
      );
      expect(repository.lastRoute()!.position!.blockId, savedPosition.blockId);
      expect(repository.passesIntegrityCheck, isTrue);
    },
  );

  test(
    'catalog refresh preserves detail fields and replaces one cache copy',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'novelia-gateway-cache-contract-',
      );
      final databasePath = '${directory.path}/reader.sqlite3';
      late SqliteOfflineRepository repository;
      addTearDown(() {
        repository.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final gateway = _StatefulNoveliaGateway();
      final epoch = DateTime.utc(2026, 8, 17, 12);
      var tick = 0;
      DateTime clock() => epoch.add(Duration(seconds: tick++));
      repository = SqliteOfflineRepository.openFile(databasePath);
      var content = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        clock: clock,
      );

      final catalog = await content.loadCatalog(const NoveliaCatalogQuery());
      final details = await content.loadDetails(catalog.data!.novels.single);
      await content.loadChapter(details.data!, chapterId: 'c1');
      final firstCopy = repository
          .listCopies(kind: OfflineCopyKind.cacheCopy)
          .single;
      final firstPayloadId = firstCopy.payloadId!;

      gateway.firstChapterRevised = true;
      await content.loadChapter(details.data!, chapterId: 'c1');
      await content.loadCatalog(const NoveliaCatalogQuery());

      final replacement = repository
          .listCopies(kind: OfflineCopyKind.cacheCopy)
          .single;
      expect(replacement.id, firstCopy.id);
      expect(replacement.payloadId, isNot(firstPayloadId));
      expect(repository.chapterPayloadById(firstPayloadId), isNull);
      repository.close();

      repository = SqliteOfflineRepository.openFile(databasePath);
      content = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        clock: clock,
      );
      final restored = repository.novelDetail(_key.stableId)!;
      expect(restored.outline.author, '作者');
      expect(restored.outline.wordCount, 1000);
      expect(restored.synopsis, '简介');
      expect(
        repository.listCopies(kind: OfflineCopyKind.cacheCopy),
        hasLength(1),
      );
      expect(repository.passesIntegrityCheck, isTrue);
    },
  );
}

const _key = NoveliaNovelKey(providerId: 'syosetu', novelId: 'n8439ed');

class _StatefulNoveliaGateway implements NoveliaGateway {
  bool online = true;
  bool secondChapterTranslated = false;
  bool firstChapterRevised = false;

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listNovels(
    NoveliaCatalogQuery query,
  ) async {
    _requireOnline();
    return NoveliaPage(items: [_outline], pageCount: 1);
  }

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listRankings(
    NoveliaRankingQuery query,
  ) async {
    _requireOnline();
    return NoveliaPage(items: [_outline], pageCount: 1);
  }

  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) async {
    _requireOnline();
    return _details;
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId,
  ) async {
    _requireOnline();
    return switch (chapterId) {
      'c1' => _chapter(
        chapterId: 'c1',
        japanese: firstChapterRevised ? const ['第一章修订', ''] : const ['第一章', ''],
        sakura: firstChapterRevised
            ? const ['第一章修订译文', '']
            : const ['第一章译文', ''],
      ),
      'c2' => _chapter(
        chapterId: 'c2',
        japanese: const ['第二章', ''],
        sakura: secondChapterTranslated ? const ['第二章译文', ''] : const [],
      ),
      _ => throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.notFound,
        'Chapter fixture not found.',
      ),
    };
  }

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    NoveliaNovelKey key, {
    int page = 0,
    int pageSize = 10,
  }) async {
    _requireOnline();
    return const NoveliaPage(items: [], pageCount: 0);
  }

  void _requireOnline() {
    if (!online) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'Simulated offline transport.',
      );
    }
  }

  NoveliaNovelOutline get _outline => NoveliaNovelOutline(
    key: _key,
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    publicationType: '连载中',
    extra: null,
    attentions: const ['一般向'],
    keywords: const ['幻想'],
    totalChapters: 2,
    originalChapters: 2,
    baiduChapters: 0,
    youdaoChapters: 2,
    gptChapters: 0,
    sakuraChapters: secondChapterTranslated ? 2 : 1,
    updatedAt: DateTime.utc(2026, 8, 17),
  );

  NoveliaNovelDetails get _details => NoveliaNovelDetails(
    key: _key,
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    authors: const [NoveliaAuthor(name: '作者')],
    publicationType: '连载中',
    attentions: const ['一般向'],
    keywords: const ['幻想'],
    points: 42,
    totalCharacters: 1000,
    japaneseIntroduction: '紹介',
    chineseIntroduction: '简介',
    toc: [
      const NoveliaTocEntry(
        japaneseTitle: '第一巻',
        chineseTitle: '第一卷',
        chapterId: null,
        createdAt: null,
      ),
      NoveliaTocEntry(
        japaneseTitle: '第一話',
        chineseTitle: '第一章',
        chapterId: 'c1',
        createdAt: DateTime.utc(2026, 8, 16),
      ),
      NoveliaTocEntry(
        japaneseTitle: '第二話',
        chineseTitle: '第二章',
        chapterId: 'c2',
        createdAt: DateTime.utc(2026, 8, 17),
      ),
    ],
    visited: 99,
    syncedAt: DateTime.utc(2026, 8, 17),
    originalChapters: 2,
    baiduChapters: 0,
    youdaoChapters: 2,
    gptChapters: 0,
    sakuraChapters: secondChapterTranslated ? 2 : 1,
  );

  static NoveliaChapterPayload _chapter({
    required String chapterId,
    required List<String> japanese,
    required List<String> sakura,
  }) {
    return NoveliaChapterPayload(
      key: _key,
      chapterId: chapterId,
      japaneseTitle: '$chapterId-title',
      chineseTitle: '$chapterId-标题',
      novelJapaneseTitle: '夜の列車',
      novelChineseTitle: '夜行列车',
      previousChapterId: chapterId == 'c1' ? null : 'c1',
      nextChapterId: chapterId == 'c1' ? 'c2' : null,
      originalParagraphs: japanese,
      baiduParagraphs: const [],
      youdaoParagraphs: [
        for (final block in japanese) block.isEmpty ? '' : '$block-有道',
      ],
      gptParagraphs: const [],
      sakuraParagraphs: sakura,
    );
  }
}
