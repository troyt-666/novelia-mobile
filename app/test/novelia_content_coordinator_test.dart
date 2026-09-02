import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);

  group('LiveFirstNoveliaContentCoordinator', () {
    test(
      'keeps catalog/detail body-free and atomically caches a chapter read',
      () async {
        final store = _openStore();
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(),
          chapters: {'c1': _payload('c1')},
        );
        final cachedChapters = <String>[];
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
          onChapterCached:
              ({required String novelId, required String chapterId}) {
                cachedChapters.add('$novelId::$chapterId');
              },
        );

        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );

        expect(catalog.availability, CatalogAvailability.available);
        expect(catalog.origin, NoveliaContentOrigin.live);
        final outline = catalog.data!.novels.single;
        expect(outline.readerNovel, isNull);
        expect(outline.declaredChapterCount, 2);
        expect(gateway.chapterCalls, isEmpty);
        expect(store.listCachedNovels(), hasLength(1));

        final detail = await coordinator.loadDetails(outline);

        expect(detail.availability, CatalogAvailability.available);
        expect(detail.data!.readerNovel!.chapters, hasLength(2));
        expect(
          detail.data!.readerNovel!.chapters.every(
            (chapter) => chapter.blocks.isEmpty,
          ),
          isTrue,
        );
        expect(gateway.chapterCalls, isEmpty);
        expect(store.novelDetail(outline.id), isNotNull);

        final chapter = await coordinator.loadChapter(
          detail.data!,
          chapterId: 'c1',
          cacheTranslationSource: TranslationSource.youdao,
        );

        expect(chapter.availability, CatalogAvailability.available);
        expect(chapter.data!.blocks.map((block) => block.japanese), ['一', '']);
        expect(gateway.chapterCalls, ['c1']);
        expect(
          store.chapterPayload(novelId: outline.id, chapterId: 'c1'),
          isNotNull,
        );
        final copy = store.listCopies(kind: OfflineCopyKind.cacheCopy).single;
        expect(copy.payloadId, isNotNull);
        expect(copy.translationSource, TranslationSource.youdao);
        expect(cachedChapters, ['${_key.stableId}::c1']);
        expect(
          coordinator.cachedChapter(detail.data!, chapterId: 'c1')?.id,
          'c1',
        );
      },
    );

    test(
      'caps an over-reported ranking counter at the original total',
      () async {
        final store = _openStore();
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(
            items: [_outline(totalChapters: 190, youdaoChapters: 191)],
            pageCount: 2,
          ),
          details: _details(),
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        );

        final result = await coordinator.loadRankings(
          NoveliaRankingQuery.syosetu(page: 1),
        );

        expect(result.availability, CatalogAvailability.available);
        expect(result.data!.totalPages, 2);
        final novel = result.data!.novels.single;
        expect(novel.declaredChapterCount, 190);
        expect(
          novel.coverageFor(TranslationSource.youdao.label)!.translatedChapters,
          190,
        );
        expect(store.listCachedNovels(), hasLength(1));
      },
    );

    test(
      'falls back through normalized outline, detail, and chapter cache',
      () async {
        const cacheAdapter = NoveliaContentCacheAdapter();
        final store = _openStore();
        store.upsertNovelOutline(
          cacheAdapter.cacheOutline(_outline(), fetchedAt: now),
        );
        store.upsertNovelDetail(
          cacheAdapter.cacheDetails(_details(), fetchedAt: now),
        );
        final cachedPayload = cacheAdapter.cacheChapter(
          _payload('c1'),
          metadata: _metadata('c1', 1),
          fetchedAt: now,
        );
        store.cacheChapterPayload(
          payload: cachedPayload,
          copy: cacheAdapter.cacheCopy(
            cachedPayload,
            translationSource: TranslationSource.sakura,
            storedAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(),
          catalogFailure: _networkFailure,
          detailFailure: _networkFailure,
          chapterFailure: _networkFailure,
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        );

        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        expect(catalog.availability, CatalogAvailability.offline);
        expect(catalog.origin, NoveliaContentOrigin.cache);

        final detail = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );
        expect(detail.availability, CatalogAvailability.offline);
        expect(detail.origin, NoveliaContentOrigin.cache);
        expect(detail.data!.readerNovel!.chapters, hasLength(2));

        final chapter = await coordinator.loadChapter(
          detail.data!,
          chapterId: 'c1',
        );
        expect(chapter.availability, CatalogAvailability.offline);
        expect(chapter.origin, NoveliaContentOrigin.cache);
        expect(chapter.data!.blocks.map((block) => block.japanese), ['一', '']);
      },
    );

    test(
      'rejects unsafe queries and an R18 detail without fetching bodies',
      () async {
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(attentions: const ['R18']),
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
        );

        final unsafe = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(contentLevel: 0),
        );
        expect(unsafe.availability, CatalogAvailability.authenticationRequired);
        expect(gateway.catalogCalls, 0);

        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        final detail = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );
        expect(detail.availability, CatalogAvailability.authenticationRequired);
        expect(detail.data, isNull);
        expect(gateway.chapterCalls, isEmpty);
      },
    );

    test(
      'authenticated access admits official all and R18 catalog levels',
      () async {
        var signedIn = true;
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(
            items: [
              _outline(attentions: const ['R18']),
            ],
            pageCount: 1,
          ),
          details: _details(attentions: const ['R18']),
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          canAccessRestrictedContent: () => signedIn,
        );

        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(contentLevel: 2),
        );
        expect(catalog.availability, CatalogAvailability.available);
        expect(catalog.data!.novels.single.tags, contains('R18'));
        final detail = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );
        expect(detail.availability, CatalogAvailability.available);

        signedIn = false;
        final denied = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );
        expect(denied.availability, CatalogAvailability.authenticationRequired);

        signedIn = true;
        final all = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(contentLevel: 0),
        );
        expect(all.availability, CatalogAvailability.available);
      },
    );

    test(
      'revokes a previously general novel after a restricted detail',
      () async {
        final store = _openStore();
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(chapterIds: const ['c1']),
          chapters: {'c1': _payload('c1')},
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        );
        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        final outline = catalog.data!.novels.single;
        final general = await coordinator.loadDetails(outline);
        await coordinator.loadChapter(general.data!, chapterId: 'c1');
        expect(store.listCachedNovels(), hasLength(1));
        expect(store.listCopies(kind: OfflineCopyKind.cacheCopy), hasLength(1));

        gateway.details = _details(
          attentions: const ['R18'],
          chapterIds: const ['c1'],
        );
        final restricted = await coordinator.loadDetails(outline);

        expect(
          restricted.availability,
          CatalogAvailability.authenticationRequired,
        );
        expect(store.listCachedNovels(), isEmpty);
        expect(store.listCopies(kind: OfflineCopyKind.cacheCopy), isEmpty);
        final chapterCallsBeforeDeniedRead = gateway.chapterCalls.length;
        final deniedChapter = await coordinator.loadChapter(
          general.data!,
          chapterId: 'c1',
        );
        expect(
          deniedChapter.availability,
          CatalogAvailability.authenticationRequired,
        );
        expect(gateway.chapterCalls, hasLength(chapterCallsBeforeDeniedRead));

        gateway.details = _details(chapterIds: const ['c1']);
        final stillDenied = await coordinator.loadDetails(outline);
        expect(
          stillDenied.availability,
          CatalogAvailability.authenticationRequired,
        );
        expect(gateway.detailCalls, 2);
      },
    );

    test('a restricted catalog reclassification stays denied', () async {
      final store = _openStore();
      final gateway = _FakeGateway(
        catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
        details: _details(),
      );
      final coordinator = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: store,
        clock: () => now,
      );
      expect(
        (await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        )).data!.novels,
        hasLength(1),
      );

      gateway.catalogPage = NoveliaPage(
        items: [
          _outline(attentions: const ['R18']),
        ],
        pageCount: 1,
      );
      expect(
        (await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        )).data!.novels,
        isEmpty,
      );
      expect(store.listCachedNovels(), isEmpty);

      gateway.catalogPage = NoveliaPage(items: [_outline()], pageCount: 1);
      expect(
        (await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        )).data!.novels,
        isEmpty,
      );
      expect(store.listCachedNovels(), isEmpty);
    });

    test(
      'persists a restricted marker when an intent retains the manifest',
      () async {
        final store = _openStore();
        store.saveIntent(
          NovelDownloadIntent(
            id: 'retained-intent',
            novelId: _key.stableId,
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(),
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        );
        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        final outline = catalog.data!.novels.single;
        await coordinator.loadDetails(outline);

        gateway.details = _details(attentions: const ['R18']);
        await coordinator.loadDetails(outline);

        expect(store.listCachedNovels(), hasLength(1));
        expect(store.listCachedNovels().single.tags, contains('R18'));

        gateway.details = _details();
        final relaunched = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        );
        final live = await relaunched.loadCatalog(const NoveliaCatalogQuery());
        expect(live.availability, CatalogAvailability.available);
        expect(live.data!.novels, isEmpty);
        expect(store.listCachedNovels().single.tags, contains('R18'));

        final detailCallsBeforeResume = gateway.detailCalls;
        final deniedResume = await AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now,
        ).synchronizeIntent('retained-intent');
        expect(
          deniedResume.availability,
          CatalogAvailability.authenticationRequired,
        );
        expect(gateway.detailCalls, detailCallsBeforeResume);

        gateway.catalogFailure = _networkFailure;
        final offline = await LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
        ).loadCatalog(const NoveliaCatalogQuery());
        expect(offline.availability, CatalogAvailability.offline);
        expect(offline.data!.novels, isEmpty);
        expect(store.listCachedNovels().single.tags, contains('R18'));
      },
    );

    test(
      'announces a chapter cache only after the atomic write succeeds',
      () async {
        final store = _openStore();
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(chapterIds: const ['c1']),
          chapters: {'c1': _payload('c1')},
        );
        var callbackCount = 0;
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
          contentRepository: store,
          clock: () => now,
          onChapterCached:
              ({required String novelId, required String chapterId}) {
                callbackCount += 1;
              },
        );
        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        final detail = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );
        store.close();

        final chapter = await coordinator.loadChapter(
          detail.data!,
          chapterId: 'c1',
        );

        expect(chapter.availability, CatalogAvailability.available);
        expect(callbackCount, 0);
      },
    );

    test(
      'uses one-based comment semantics and redacts hidden content',
      () async {
        final gateway = _FakeGateway(
          catalogPage: NoveliaPage(items: [_outline()], pageCount: 1),
          details: _details(),
          comments: NoveliaPage(
            pageCount: 3,
            items: [
              NoveliaComment(
                id: 'hidden',
                username: 'reader',
                content: 'do not expose',
                hidden: true,
                createdAt: now,
                replies: const [],
              ),
            ],
          ),
        );
        final coordinator = LiveFirstNoveliaContentCoordinator(
          gateway: gateway,
        );
        final catalog = await coordinator.loadCatalog(
          const NoveliaCatalogQuery(),
        );
        final detail = await coordinator.loadDetails(
          catalog.data!.novels.single,
        );

        final comments = await coordinator.loadComments(
          detail.data!,
          pageNumber: 2,
        );

        expect(comments.availability, CatalogAvailability.available);
        expect(comments.data!.pageNumber, 2);
        expect(comments.data!.totalPages, 3);
        expect(
          comments.data!.comments.single.body,
          NoveliaDomainAdapter.hiddenCommentBody,
        );
        expect(gateway.lastCommentPage, 1);
        expect(gateway.lastCommentKey!.commentSite, 'web-syosetu-n8439ed');
      },
    );
  });

  group('AsyncNoveliaDownloadCoordinator', () {
    test(
      'reconciles future chapters and stores pending Japanese atomically',
      () async {
        final store = _openStore();
        store.saveIntent(
          NovelDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: const ['c1']),
          chapters: {
            'c1': _payload('c1', sakura: const ['甲', '']),
            'c2': _payload('c2', sakura: const []),
          },
        );
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now,
        );

        final first = await coordinator.synchronizeIntent('intent');
        expect(first.createdTaskCount, 1);
        expect(first.tasks.single.state, DownloadTaskState.stored);

        gateway.details = _details(chapterIds: const ['c1', 'c2']);
        final second = await coordinator.synchronizeIntent('intent');

        expect(second.createdTaskCount, 1);
        expect(second.tasks, hasLength(2));
        expect(
          second.tasks.every((task) => task.state == DownloadTaskState.stored),
          isTrue,
        );
        expect(gateway.chapterCalls, ['c1', 'c2']);
        expect(
          store.chapterPayload(novelId: _key.stableId, chapterId: 'c1'),
          isNotNull,
        );
        expect(
          store.chapterPayload(novelId: _key.stableId, chapterId: 'c2'),
          isNotNull,
        );
        final pendingCopy = store
            .listCopies(kind: OfflineCopyKind.offlineDownload)
            .singleWhere((copy) => copy.chapterId == 'c2');
        expect(pendingCopy.originalBytes, greaterThan(0));
        expect(pendingCopy.translationBytes, isNull);
        expect(
          store
              .chapterPayload(novelId: _key.stableId, chapterId: 'c2')!
              .translationFor(TranslationSource.sakura)!
              .availability,
          TranslationAvailability.pending,
        );
      },
    );

    test(
      'permanently fails a mismatched selected translation revision',
      () async {
        final store = _openStore();
        store.saveIntent(
          ChapterDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            chapterId: 'c1',
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: const ['c1']),
          chapters: {
            'c1': _payload('c1', sakura: const ['only one']),
          },
        );
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now,
        );

        final first = await coordinator.synchronizeIntent('intent');
        final failed = first.tasks.single;
        expect(failed.state, DownloadTaskState.failed);
        expect(failed.failure!.kind, DownloadFailureKind.validation);
        expect(failed.failure!.retryable, isFalse);
        expect(
          store.chapterPayload(novelId: _key.stableId, chapterId: 'c1'),
          isNull,
        );
        expect(store.listCopies(), isEmpty);

        final second = await coordinator.synchronizeIntent('intent');
        expect(second.createdTaskCount, 0);
        expect(second.tasks.single.state, DownloadTaskState.failed);
        expect(gateway.chapterCalls, ['c1']);
      },
    );

    test(
      'refreshes a stored pending copy to complete without reopening task',
      () async {
        final store = _openStore();
        store.saveIntent(
          ChapterDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            chapterId: 'c1',
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: const ['c1']),
          chapters: {'c1': _payload('c1', sakura: const [])},
        );
        var tick = 0;
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now.add(Duration(seconds: tick++)),
        );

        final first = await coordinator.synchronizeIntent('intent');
        final storedTask = first.tasks.single;
        final originalCopy = store.copyById(storedTask.storedCopyId!)!;
        final originalPayloadId = originalCopy.payloadId!;
        expect(originalCopy.translationBytes, isNull);

        gateway.chapters['c1'] = _payload('c1', sakura: const ['译文', '']);
        final second = await coordinator.synchronizeIntent('intent');

        expect(second.refreshedCopyCount, 1);
        expect(second.refreshFailureCount, 0);
        final refreshedTask = second.tasks.single;
        expect(refreshedTask.state, DownloadTaskState.stored);
        expect(refreshedTask.storedCopyId, storedTask.storedCopyId);
        final refreshedCopy = store.copyById(refreshedTask.storedCopyId!)!;
        expect(refreshedCopy.id, originalCopy.id);
        expect(refreshedCopy.payloadId, isNot(originalPayloadId));
        expect(refreshedCopy.translationBytes, greaterThan(0));
        expect(
          store
              .chapterPayloadById(refreshedCopy.payloadId!)!
              .translationFor(TranslationSource.sakura)!
              .availability,
          TranslationAvailability.complete,
        );
        expect(gateway.chapterCalls, ['c1', 'c1']);
      },
    );

    test(
      'refreshes the Japanese revision and stores mismatch as invalid',
      () async {
        final store = _openStore();
        store.saveIntent(
          ChapterDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            chapterId: 'c1',
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: const ['c1']),
          chapters: {
            'c1': _payload('c1', original: const ['旧版'], sakura: const []),
          },
        );
        var tick = 0;
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now.add(Duration(seconds: tick++)),
        );

        final first = await coordinator.synchronizeIntent('intent');
        final task = first.tasks.single;
        final firstCopy = store.copyById(task.storedCopyId!)!;
        final firstPayloadId = firstCopy.payloadId!;

        gateway.chapters['c1'] = _payload(
          'c1',
          original: const ['新版一', ''],
          sakura: const ['partial'],
        );
        final second = await coordinator.synchronizeIntent('intent');

        expect(second.refreshedCopyCount, 1);
        expect(second.tasks.single.state, DownloadTaskState.stored);
        final refreshedCopy = store.copyById(task.storedCopyId!)!;
        expect(refreshedCopy.payloadId, isNot(firstPayloadId));
        expect(refreshedCopy.translationBytes, isNull);
        final refreshedPayload = store.chapterPayloadById(
          refreshedCopy.payloadId!,
        )!;
        expect(refreshedPayload.japaneseBlocks, ['新版一', '']);
        expect(
          refreshedPayload
              .translationFor(TranslationSource.sakura)!
              .availability,
          TranslationAvailability.invalid,
        );
        final restored = const NoveliaContentCacheAdapter().restoreChapter(
          refreshedPayload,
        );
        expect(
          restored.blocks.every(
            (block) =>
                !block.translations.containsKey(TranslationSource.sakura),
          ),
          isTrue,
        );
        expect(store.chapterPayloadById(firstPayloadId), isNull);
      },
    );

    test(
      'rotates bounded refreshes so candidates beyond the limit run',
      () async {
        const chapterIds = ['c0', 'c1', 'c2', 'c3', 'c4'];
        final store = _openStore();
        store.saveIntent(
          NovelDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: chapterIds),
          chapters: {
            for (final chapterId in chapterIds)
              chapterId: _payload(chapterId, sakura: const []),
          },
        );
        var tick = 0;
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          maximumStoredRefreshesPerRun: 2,
          clock: () => now.add(Duration(seconds: tick++)),
        );
        await coordinator.synchronizeIntent('intent');
        gateway.chapterCalls.clear();
        gateway.chapters.remove('c0');
        gateway.chapters.remove('c1');

        final firstRefresh = await coordinator.synchronizeIntent('intent');
        final secondRefresh = await coordinator.synchronizeIntent('intent');
        final thirdRefresh = await coordinator.synchronizeIntent('intent');

        expect(firstRefresh.refreshFailureCount, 2);
        expect(secondRefresh.refreshedCopyCount, 2);
        expect(gateway.chapterCalls.take(4), ['c0', 'c1', 'c2', 'c3']);
        expect(gateway.chapterCalls.toSet(), containsAll(chapterIds));
        expect(thirdRefresh.refreshedCopyCount, 1);
        expect(thirdRefresh.refreshFailureCount, 1);
      },
    );

    test(
      'pause during fetch stops cooperatively and later resume continues',
      () async {
        final store = _openStore();
        store.saveIntent(
          NovelDownloadIntent(
            id: 'intent',
            novelId: _key.stableId,
            translationSource: TranslationSource.sakura,
            createdAt: now,
          ),
        );
        final blocked = Completer<NoveliaChapterPayload>();
        final gateway = _FakeGateway(
          catalogPage: const NoveliaPage(items: [], pageCount: 0),
          details: _details(chapterIds: const ['c1', 'c2']),
          chapters: {'c1': _payload('c1'), 'c2': _payload('c2')},
          chapterBlock: blocked,
        );
        final coordinator = AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: store,
          offlineRepository: store,
          clock: () => now,
        );

        final inFlight = coordinator.synchronizeIntent('intent');
        await Future<void>.delayed(Duration.zero);
        expect(gateway.chapterCalls, ['c1']);
        store.pauseIntent('intent', now.add(const Duration(seconds: 1)));
        blocked.complete(gateway.chapters['c1']!);
        final pausedRun = await inFlight;

        expect(
          pausedRun.tasks.every(
            (task) => task.state != DownloadTaskState.fetching,
          ),
          isTrue,
        );
        expect(
          pausedRun.tasks.any((task) => task.state == DownloadTaskState.stored),
          isFalse,
        );

        gateway.chapterBlock = null;
        store.resumeIntent('intent', now.add(const Duration(seconds: 2)));
        final resumed = await coordinator.synchronizeIntent('intent');
        expect(
          resumed.tasks.every((task) => task.state == DownloadTaskState.stored),
          isTrue,
        );
      },
    );

    test('pause stops pending-translation refreshes cooperatively', () async {
      final store = _openStore();
      store.saveIntent(
        NovelDownloadIntent(
          id: 'intent',
          novelId: _key.stableId,
          translationSource: TranslationSource.sakura,
          createdAt: now,
        ),
      );
      final gateway = _FakeGateway(
        catalogPage: const NoveliaPage(items: [], pageCount: 0),
        details: _details(chapterIds: const ['c1', 'c2']),
        chapters: {
          'c1': _payload('c1', sakura: const []),
          'c2': _payload('c2', sakura: const []),
        },
      );
      final coordinator = AsyncNoveliaDownloadCoordinator(
        gateway: gateway,
        contentRepository: store,
        offlineRepository: store,
        clock: () => now,
      );
      await coordinator.synchronizeIntent('intent');
      expect(
        store
            .listCopies(kind: OfflineCopyKind.offlineDownload)
            .every((copy) => copy.translationBytes == null),
        isTrue,
      );

      gateway.chapterCalls.clear();
      final blocked = Completer<NoveliaChapterPayload>();
      gateway.chapterBlock = blocked;
      final inFlight = coordinator.synchronizeIntent('intent');
      await Future<void>.delayed(Duration.zero);
      expect(gateway.chapterCalls, ['c1']);

      store.pauseIntent('intent', now.add(const Duration(seconds: 1)));
      blocked.complete(_payload('c1'));
      final pausedRun = await inFlight;

      expect(gateway.chapterCalls, ['c1']);
      expect(pausedRun.refreshedCopyCount, 0);
      expect(
        store
            .listCopies(kind: OfflineCopyKind.offlineDownload)
            .every((copy) => copy.translationBytes == null),
        isTrue,
      );
    });
  });
}

const _key = NoveliaNovelKey(providerId: 'syosetu', novelId: 'n8439ed');

const _networkFailure = NoveliaGatewayException(
  NoveliaGatewayFailureKind.network,
  'offline',
);

NoveliaNovelOutline _outline({
  List<String> attentions = const ['一般向'],
  int totalChapters = 2,
  int? youdaoChapters,
}) {
  return NoveliaNovelOutline(
    key: _key,
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    publicationType: '连载中',
    extra: null,
    attentions: attentions,
    keywords: const ['幻想'],
    totalChapters: totalChapters,
    originalChapters: totalChapters,
    baiduChapters: 0,
    youdaoChapters: youdaoChapters ?? totalChapters,
    gptChapters: totalChapters == 0 ? 0 : 1,
    sakuraChapters: totalChapters == 0 ? 0 : 1,
    updatedAt: DateTime.utc(2026, 8, 17),
  );
}

NoveliaNovelDetails _details({
  List<String> attentions = const ['一般向'],
  List<String> chapterIds = const ['c1', 'c2'],
}) {
  return NoveliaNovelDetails(
    key: _key,
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    authors: const [NoveliaAuthor(name: '作者')],
    publicationType: '连载中',
    attentions: attentions,
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
      for (var index = 0; index < chapterIds.length; index++)
        NoveliaTocEntry(
          japaneseTitle: '第${index + 1}話',
          chineseTitle: '第${index + 1}章',
          chapterId: chapterIds[index],
          createdAt: DateTime.utc(2026, 8, 16 + index),
        ),
    ],
    visited: 99,
    syncedAt: DateTime.utc(2026, 8, 17),
    originalChapters: chapterIds.length,
    baiduChapters: 0,
    youdaoChapters: chapterIds.length,
    gptChapters: 0,
    sakuraChapters: chapterIds.isEmpty ? 0 : 1,
  );
}

NoveliaChapterPayload _payload(
  String chapterId, {
  List<String> original = const ['一', ''],
  List<String> sakura = const ['甲', ''],
}) {
  return NoveliaChapterPayload(
    key: _key,
    chapterId: chapterId,
    japaneseTitle: '$chapterId-title',
    chineseTitle: '$chapterId-标题',
    novelJapaneseTitle: '夜の列車',
    novelChineseTitle: '夜行列车',
    previousChapterId: null,
    nextChapterId: null,
    originalParagraphs: original,
    baiduParagraphs: const [],
    youdaoParagraphs: [for (final block in original) block.isEmpty ? '' : '甲'],
    gptParagraphs: const [],
    sakuraParagraphs: sakura,
  );
}

NovelChapter _metadata(String chapterId, int index) {
  return NovelChapter(
    id: chapterId,
    index: index,
    chineseTitle: '$chapterId-标题',
    japaneseTitle: '$chapterId-title',
    publishedAt: DateTime.utc(2026, 8, 16 + index),
    blocks: const [],
  );
}

class _FakeGateway implements NoveliaGateway {
  _FakeGateway({
    required this.catalogPage,
    required this.details,
    this.chapters = const {},
    this.comments = const NoveliaPage(items: [], pageCount: 0),
    this.catalogFailure,
    this.detailFailure,
    this.chapterFailure,
    this.chapterBlock,
  });

  NoveliaPage<NoveliaNovelOutline> catalogPage;
  NoveliaNovelDetails details;
  Map<String, NoveliaChapterPayload> chapters;
  NoveliaPage<NoveliaComment> comments;
  NoveliaGatewayException? catalogFailure;
  NoveliaGatewayException? detailFailure;
  NoveliaGatewayException? chapterFailure;
  Completer<NoveliaChapterPayload>? chapterBlock;

  int catalogCalls = 0;
  int detailCalls = 0;
  final List<String> chapterCalls = [];
  final List<(int, int?)> progressReports = [];
  NoveliaNovelKey? lastCommentKey;
  int? lastCommentPage;

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listNovels(
    NoveliaCatalogQuery query,
  ) async {
    catalogCalls += 1;
    if (catalogFailure case final failure?) throw failure;
    return catalogPage;
  }

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listRankings(
    NoveliaRankingQuery query,
  ) async {
    if (catalogFailure case final failure?) throw failure;
    return catalogPage;
  }

  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) async {
    detailCalls += 1;
    if (detailFailure case final failure?) throw failure;
    return details;
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
  }) async {
    chapterCalls.add(chapterId);
    if (chapterFailure case final failure?) throw failure;
    if (chapterBlock case final blocked?) {
      onReceiveProgress?.call(40, 80);
      progressReports.add((40, 80));
      return blocked.future;
    }
    final payload =
        chapters[chapterId] ??
        (throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.notFound,
          'missing fixture chapter',
        ));
    onReceiveProgress?.call(20, 20);
    progressReports.add((20, 20));
    return payload;
  }

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    NoveliaNovelKey key, {
    int page = 0,
    int pageSize = 10,
  }) async {
    lastCommentKey = key;
    lastCommentPage = page;
    return comments;
  }
}

SqliteOfflineRepository _openStore() {
  final store = SqliteOfflineRepository.openInMemory();
  addTearDown(store.close);
  return store;
}
