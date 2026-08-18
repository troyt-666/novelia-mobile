import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/database/local_state_repository.dart';
import 'package:novelia_reader/core/database/sqlite_offline_repository.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/core/offline/content_models.dart';
import 'package:novelia_reader/core/offline/offline_models.dart';
import 'package:novelia_reader/core/platform/external_link_launcher.dart';
import 'package:novelia_reader/features/discover/catalog_models.dart';
import 'package:novelia_reader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:novelia_reader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:novelia_reader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:novelia_reader/gateway/novelia/novelia_gateway.dart';
import 'package:novelia_reader/main.dart';

void main() {
  testWidgets(
    'production runtime loads live content and resumes before launch',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final coordinator = _RuntimeCoordinator();
      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: coordinator.outline.id,
          position: const ReadingPosition(
            chapterId: 'chapter-3',
            blockId: 'chapter-3:0',
          ),
          updatedAt: DateTime.utc(2026, 8, 17),
        ),
      );

      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: coordinator,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('线上目录小说'), findsWidgets);
      expect(find.text('星轨夹层'), findsNothing);

      final continueButton = find.byKey(
        ValueKey('continue-reading-${coordinator.outline.id}'),
      );
      tester.widget<InkWell>(continueButton).onTap!();
      await tester.pumpAndSettle();
      expect(coordinator.detailRequests, 1);

      expect(coordinator.loadedChapterIds, ['chapter-3']);
      expect(find.byKey(const ValueKey('reader-stream')), findsOneWidget);
      expect(repository.lastRoute()?.position?.chapterId, 'chapter-3');
    },
  );

  testWidgets(
    'production catalog searches remotely and appends the next page',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final coordinator = _PagedCatalogCoordinator();
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: coordinator,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('目录第一页'), findsWidgets);
      expect(
        coordinator.queries.map((query) => query.sort),
        containsAll([0, 1]),
      );
      await tester.tap(find.byKey(const ValueKey('open-rankings-button')));
      await tester.pumpAndSettle();
      expect(find.text('服务排行第一'), findsWidgets);
      expect(find.textContaining('服务原生排序'), findsOneWidget);
      expect(coordinator.rankingQueries.single.providerId, 'syosetu');
      expect(coordinator.rankingQueries.single.parameters['genre'], '恋爱：异世界');
      expect(coordinator.rankingQueries.single.parameters['page'], '1');
      await tester.tap(find.byKey(const ValueKey('rankings-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('服务排行第二'), findsWidgets);
      expect(coordinator.rankingQueries.last.parameters['page'], '2');
      Navigator.of(
        tester.element(find.byKey(const ValueKey('rankings-screen'))),
      ).pop();
      await tester.pumpAndSettle();

      final footer = find.byKey(const ValueKey('load-next-catalog-page'));
      await tester.scrollUntilVisible(
        footer,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final loadButton = find.byKey(const ValueKey('load-next-catalog-page'));
      if (loadButton.evaluate().isNotEmpty) {
        await tester.tap(loadButton);
        await tester.pumpAndSettle();
      }
      expect(coordinator.queries.any((query) => query.page == 1), isTrue);
      expect(find.text('目录第二页'), findsWidgets);

      final search = find.byKey(const ValueKey('discover-search-field'));
      await tester.scrollUntilVisible(
        search,
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(search, '远程命中');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(coordinator.queries.last.search, '远程命中');
      expect(find.text('远程命中小说'), findsWidgets);
    },
  );

  testWidgets('restored catalog stays offline until a live request succeeds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    repository.upsertNovelOutline(
      CachedNovelOutline(
        id: 'syosetu/cached-startup',
        chineseTitle: '缓存启动小说',
        japaneseTitle: 'キャッシュ起動小説',
        author: '缓存作者',
        contentSource: 'Syosetu',
        publicationState: CachedNovelState.ongoing,
        chapterCount: 1,
        wordCount: null,
        updatedAt: DateTime.utc(2026, 8, 16),
        tags: const [],
        translationCoverage: const [],
        fetchedAt: DateTime.utc(2026, 8, 16),
      ),
    );
    final coordinator = _DelayedCatalogCoordinator();

    await tester.pumpWidget(
      NoveliaReaderApp(repository: repository, contentCoordinator: coordinator),
    );
    await tester.pump();

    expect(find.text('缓存启动小说'), findsWidgets);
    expect(find.text('当前处于离线状态'), findsOneWidget);

    coordinator.complete();
    await tester.pumpAndSettle();
    expect(find.text('实时启动小说'), findsWidgets);
    expect(find.text('当前处于离线状态'), findsNothing);
  });

  testWidgets('typed catalog controls reach the service query boundary', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final coordinator = _PagedCatalogCoordinator();
    await tester.pumpWidget(
      NoveliaReaderApp(repository: repository, contentCoordinator: coordinator),
    );
    await tester.pumpAndSettle();

    final filters = find.byKey(const ValueKey('discover-filters-button'));
    await tester.scrollUntilVisible(
      filters,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(filters);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-source-Syosetu')));
    await tester.pumpAndSettle();
    expect(coordinator.queries.last.providers, const ['syosetu']);

    await tester.tap(find.byKey(const ValueKey('filter-state-ongoing')));
    await tester.pumpAndSettle();
    expect(coordinator.queries.last.publicationType, 1);

    await tester.tap(find.byKey(const ValueKey('filter-translation-Sakura')));
    await tester.pumpAndSettle();
    expect(coordinator.queries.last.translationFilter, 2);

    await tester.tap(find.byKey(const ValueKey('catalog-sort-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多点击').last);
    await tester.pumpAndSettle();
    expect(coordinator.queries.last.sort, 1);
  });

  testWidgets('explicit chapter selection wins over older saved progress', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final coordinator = _RuntimeCoordinator();
    repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: coordinator.outline.id,
        position: const ReadingPosition(
          chapterId: 'chapter-3',
          blockId: 'chapter-3:0',
        ),
        updatedAt: DateTime.utc(2026, 8, 17),
      ),
    );

    await tester.pumpWidget(
      NoveliaReaderApp(repository: repository, contentCoordinator: coordinator),
    );
    await tester.pumpAndSettle();

    final detailCards = find.byKey(
      ValueKey('open-details-${coordinator.outline.id}'),
    );
    expect(detailCards, findsWidgets);
    tester.widget<InkWell>(detailCards.at(1)).onTap!();
    await tester.pumpAndSettle();

    final chapterToggle = find.byKey(const ValueKey('toggle-chapters-button'));
    await tester.scrollUntilVisible(
      chapterToggle,
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(chapterToggle);
    await tester.pumpAndSettle();

    final firstChapter = find.byKey(const ValueKey('chapter-chapter-1'));
    await tester.scrollUntilVisible(
      firstChapter,
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(firstChapter);
    await tester.pumpAndSettle();

    expect(repository.lastRoute()?.position?.chapterId, 'chapter-1');
    expect(
      find.byKey(const ValueKey('block-chapter-1:0-japanese')),
      findsOneWidget,
    );
  });

  testWidgets('original-site action uses the injected platform launcher', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final coordinator = _RuntimeCoordinator();
    final launcher = _RecordingExternalLinkLauncher();
    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: coordinator,
        externalLinkLauncher: launcher,
      ),
    );
    await tester.pumpAndSettle();

    final details = find.byKey(
      ValueKey('open-details-${coordinator.outline.id}'),
    );
    tester.widget<InkWell>(details.first).onTap!();
    await tester.pumpAndSettle();
    final original = find.byKey(const ValueKey('open-original-site-button'));
    await tester.scrollUntilVisible(
      original,
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(original);
    await tester.pumpAndSettle();

    expect(launcher.opened, [
      Uri.parse('https://ncode.syosetu.com/runtime-test'),
    ]);
  });

  testWidgets('startup requeues an interrupted active download task', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 8, 17);
    const intentId = 'interrupted-intent';
    repository.saveIntent(
      NovelDownloadIntent(
        id: intentId,
        novelId: 'syosetu/runtime-test',
        translationSource: TranslationSource.sakura,
        createdAt: now,
      ),
    );
    final queued = repository
        .reconcileIntent(
          intentId: intentId,
          knownChapterIds: const ['chapter-1'],
          now: now,
        )
        .single;
    repository.saveTask(queued.beginFetching(now));
    final downloads = _RecordingDownloadCoordinator(repository);

    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: _RuntimeCoordinator(),
        downloadCoordinator: downloads,
      ),
    );
    await tester.pumpAndSettle();

    expect(downloads.statesAtSynchronization, [DownloadTaskState.queued]);
  });
}

class _RuntimeCoordinator implements NoveliaContentCoordinator {
  _RuntimeCoordinator() {
    final metadata = [
      for (var index = 1; index <= 3; index++)
        NovelChapter(
          id: 'chapter-$index',
          index: index - 1,
          chineseTitle: '第$index章中文',
          japaneseTitle: '第$index章日本語',
          publishedAt: null,
          blocks: const [],
        ),
    ];
    outline = CatalogNovel(
      id: 'syosetu/runtime-test',
      chineseTitle: '线上目录小说',
      japaneseTitle: 'オンライン目録小説',
      source: 'Syosetu',
      publicationState: NovelPublicationState.ongoing,
      updatedAt: DateTime.utc(2026, 8, 17),
      tags: const ['测试'],
      translationCoverage: const [
        TranslationCoverage(
          source: 'Sakura',
          translatedChapters: 3,
          totalChapters: 3,
        ),
      ],
      declaredChapterCount: 3,
    );
    details = CatalogNovel(
      id: outline.id,
      chineseTitle: outline.chineseTitle,
      japaneseTitle: outline.japaneseTitle,
      author: '运行时作者',
      source: outline.source,
      publicationState: outline.publicationState,
      updatedAt: outline.updatedAt,
      tags: outline.tags,
      synopsis: '运行时详情',
      translationCoverage: outline.translationCoverage,
      declaredChapterCount: 3,
      readerNovel: ReaderNovel(
        id: outline.id,
        chineseTitle: outline.chineseTitle,
        japaneseTitle: outline.japaneseTitle,
        author: '运行时作者',
        chapters: metadata,
      ),
      chapterSections: const [
        CatalogChapterSection(
          title: '正文',
          chapterIds: ['chapter-1', 'chapter-2', 'chapter-3'],
        ),
      ],
      originalUrl: Uri.parse('https://ncode.syosetu.com/runtime-test'),
    );
  }

  late final CatalogNovel outline;
  late final CatalogNovel details;
  final List<String> loadedChapterIds = [];
  var detailRequests = 0;

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) async {
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(pageIndex: 0, totalPages: 1, novels: [outline]),
    );
  }

  @override
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(
    CatalogNovel outline,
  ) async {
    detailRequests += 1;
    return NoveliaContentResult.available(details);
  }

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) async {
    loadedChapterIds.add(chapterId);
    final index = int.parse(chapterId.split('-').last);
    return NoveliaContentResult.available(
      NovelChapter(
        id: chapterId,
        index: index - 1,
        chineseTitle: '第$index章中文',
        japaneseTitle: '第$index章日本語',
        publishedAt: null,
        blocks: [
          AlignedBlock(
            id: '$chapterId:0',
            ordinal: 0,
            japanese: '第$index章の本文',
            translations: {
              TranslationSource.sakura: '第$index章中文',
              TranslationSource.gpt: '第$index章中文',
              TranslationSource.youdao: '第$index章中文',
            },
          ),
        ],
      ),
    );
  }

  @override
  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  }) async {
    return NoveliaContentResult.available(
      NoveliaCommentSlice(
        pageNumber: pageNumber,
        totalPages: 0,
        comments: const [],
      ),
    );
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) async {
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(pageIndex: 0, totalPages: 1, novels: [outline]),
    );
  }
}

class _PagedCatalogCoordinator implements NoveliaContentCoordinator {
  final List<NoveliaCatalogQuery> queries = [];
  final List<NoveliaRankingQuery> rankingQueries = [];

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) async {
    queries.add(query);
    if (query.search == '远程命中') {
      return NoveliaContentResult.available(
        NoveliaCatalogSlice(
          pageIndex: 0,
          totalPages: 1,
          novels: [_outline('remote-hit', '远程命中小说')],
        ),
      );
    }
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(
        pageIndex: query.page,
        totalPages: 2,
        novels: [
          query.page == 0
              ? _outline('page-one', '目录第一页')
              : _outline('page-two', '目录第二页'),
        ],
      ),
    );
  }

  @override
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(CatalogNovel outline) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) async {
    rankingQueries.add(query);
    final page = int.parse(query.parameters['page'] ?? '1');
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(
        pageIndex: page - 1,
        totalPages: 2,
        novels: [_outline('ranking-$page', page == 1 ? '服务排行第一' : '服务排行第二')],
      ),
    );
  }

  static CatalogNovel _outline(String id, String title) {
    return CatalogNovel(
      id: 'syosetu/$id',
      chineseTitle: title,
      japaneseTitle: '$title 日本語',
      source: 'Syosetu',
      publicationState: NovelPublicationState.ongoing,
      updatedAt: DateTime.utc(2026, 8, 17),
      tags: const [],
      translationCoverage: const [
        TranslationCoverage(
          source: 'Sakura',
          translatedChapters: 1,
          totalChapters: 1,
        ),
      ],
      declaredChapterCount: 1,
    );
  }
}

class _DelayedCatalogCoordinator implements NoveliaContentCoordinator {
  final _catalog = Completer<NoveliaContentResult<NoveliaCatalogSlice>>();

  void complete() {
    _catalog.complete(
      NoveliaContentResult.available(
        NoveliaCatalogSlice(
          pageIndex: 0,
          totalPages: 1,
          novels: [_PagedCatalogCoordinator._outline('live-startup', '实时启动小说')],
        ),
      ),
    );
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) => _catalog.future;

  @override
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(CatalogNovel outline) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) {
    throw UnimplementedError();
  }
}

class _RecordingDownloadCoordinator implements NoveliaDownloadCoordinator {
  _RecordingDownloadCoordinator(this.repository);

  final SqliteOfflineRepository repository;
  final List<DownloadTaskState> statesAtSynchronization = [];

  @override
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId) async {
    final tasks = repository.listTasks(intentId: intentId);
    statesAtSynchronization.addAll(tasks.map((task) => task.state));
    return NoveliaDownloadRun(
      intentId: intentId,
      availability: CatalogAvailability.available,
      usedCachedToc: false,
      knownChapterCount: tasks.length,
      createdTaskCount: 0,
      refreshedCopyCount: 0,
      refreshFailureCount: 0,
      tasks: tasks,
    );
  }
}

class _RecordingExternalLinkLauncher implements ExternalLinkLauncher {
  final List<Uri> opened = [];

  @override
  Future<void> open(Uri uri) async => opened.add(uri);
}
