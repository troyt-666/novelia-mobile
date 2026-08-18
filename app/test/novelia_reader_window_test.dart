import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/features/discover/catalog_models.dart';
import 'package:novelia_reader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:novelia_reader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:novelia_reader/gateway/novelia/novelia_gateway.dart';
import 'package:novelia_reader/gateway/novelia/novelia_reader_window.dart';

void main() {
  test(
    'loads the requested target first and prefetches forward in background',
    () async {
      final chapters = [
        _metadata('c1', 1),
        _metadata('c2', 2),
        _metadata('c3', 3),
        _metadata('c4', 4),
        _metadata('c2', 20),
      ];
      final coordinator = _WindowCoordinator({
        for (final chapter in chapters)
          chapter.id: NoveliaContentResult.available(_loaded(chapter)),
      });
      final factory = NoveliaReaderWindowFactory(
        contentCoordinator: coordinator,
      );
      final requested = const ReadingPosition(chapterId: 'c3', blockId: 'c3:0');

      final launch = await factory.create(
        novel: _novel(chapters),
        selectedChapter: chapters[1],
        requestedPosition: requested,
        translationSource: TranslationSource.gpt,
      );

      expect(coordinator.chapterCalls.first, 'c3');
      expect(coordinator.sources, everyElement(TranslationSource.gpt));
      expect(launch.novel.chapters.map((chapter) => chapter.id), ['c3']);
      expect(launch.initialPosition, same(requested));
      expect(launch.dataSource!.catalog.map((chapter) => chapter.id), [
        'c1',
        'c2',
        'c3',
        'c4',
      ]);
      expect(launch.dataSource!.catalog.first.sectionTitle, '上卷');
      expect(launch.dataSource!.catalog.last.sectionTitle, '下卷');

      await _waitUntil(() => coordinator.chapterCalls.contains('c4'));
      expect(coordinator.chapterCalls, ['c3', 'c4']);

      final end = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c4',
          direction: ReaderLoadDirection.after,
        ),
      );
      expect(end.chapters, isEmpty);
      expect(end.after, ReaderBoundaryStatus.endOfCatalog);
      expect(coordinator.chapterCalls, ['c3', 'c4']);

      final catalogLoad = await launch.dataSource!.loadAround('c1');
      expect(catalogLoad.chapters.map((chapter) => chapter.id), ['c1']);
      expect(catalogLoad.before, ReaderBoundaryStatus.endOfCatalog);
      expect(catalogLoad.after, ReaderBoundaryStatus.loadable);
      await _waitUntil(() => coordinator.chapterCalls.contains('c2'));
      expect(coordinator.chapterCalls, ['c3', 'c4', 'c1', 'c2']);
    },
  );

  test(
    'keeps three future chapters warm and shares adjacent requests',
    () async {
      final chapters = [
        for (var number = 1; number <= 7; number++)
          _metadata('c$number', number),
      ];
      final coordinator = _WindowCoordinator({
        for (final chapter in chapters)
          chapter.id: NoveliaContentResult.available(_loaded(chapter)),
      });
      final launch =
          await NoveliaReaderWindowFactory(
            contentCoordinator: coordinator,
          ).create(
            novel: _novel(chapters),
            selectedChapter: chapters[1],
            requestedPosition: null,
            translationSource: TranslationSource.sakura,
          );

      await _waitUntil(() => coordinator.chapterCalls.contains('c5'));
      expect(coordinator.chapterCalls, ['c2', 'c3', 'c4', 'c5']);
      expect(coordinator.chapterCalls, isNot(contains('c6')));

      final adjacent = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c2',
          direction: ReaderLoadDirection.after,
        ),
      );
      expect(adjacent.chapters.map((chapter) => chapter.id), ['c3']);
      expect(coordinator.chapterCalls.where((id) => id == 'c3'), hasLength(1));

      await _waitUntil(() => coordinator.chapterCalls.contains('c6'));
      expect(coordinator.chapterCalls.where((id) => id == 'c6'), hasLength(1));
    },
  );

  test('cached window does not wait for live revalidation', () async {
    final chapters = [
      _metadata('c1', 1),
      _metadata('c2', 2),
      _metadata('c3', 3),
    ];
    final pendingRefreshes = {
      for (final chapter in chapters)
        chapter.id: Completer<NoveliaContentResult<NovelChapter>>(),
    };
    final coordinator = _WindowCoordinator(
      const {},
      cachedResponses: {
        for (final chapter in chapters) chapter.id: _loaded(chapter),
      },
      pendingResponses: pendingRefreshes,
    );

    final launch =
        await NoveliaReaderWindowFactory(contentCoordinator: coordinator)
            .create(
              novel: _novel(chapters),
              selectedChapter: chapters[1],
              requestedPosition: null,
              translationSource: TranslationSource.sakura,
            )
            .timeout(const Duration(seconds: 1));

    expect(launch.novel.chapters.map((chapter) => chapter.id), [
      'c1',
      'c2',
      'c3',
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.chapterCalls, unorderedEquals(['c1', 'c2', 'c3']));
    for (final chapter in chapters) {
      pendingRefreshes[chapter.id]!.complete(
        NoveliaContentResult.available(_loaded(chapter)),
      );
    }
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'uses cached chapters and marks an offline missing neighbor unavailable',
    () async {
      final chapters = [
        _metadata('c1', 1),
        _metadata('c2', 2),
        _metadata('c3', 3),
      ];
      final coordinator = _WindowCoordinator(
        {
          'c1': NoveliaContentResult.offline(cachedData: _loaded(chapters[0])),
          'c2': NoveliaContentResult.available(_loaded(chapters[1])),
          'c3': NoveliaContentResult.offline(failure: _networkFailure),
        },
        cachedResponses: {
          'c1': _loaded(chapters[0]),
          'c2': _loaded(chapters[1]),
        },
      );
      final launch =
          await NoveliaReaderWindowFactory(
            contentCoordinator: coordinator,
          ).create(
            novel: _novel(chapters),
            selectedChapter: chapters[1],
            requestedPosition: null,
            translationSource: TranslationSource.sakura,
          );

      expect(launch.novel.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      final around = await launch.dataSource!.loadAround('c2');
      expect(around.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      expect(around.before, ReaderBoundaryStatus.endOfCatalog);
      expect(around.after, ReaderBoundaryStatus.loadable);

      final unavailable = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c2',
          direction: ReaderLoadDirection.after,
        ),
      );
      expect(unavailable.chapters, isEmpty);
      expect(unavailable.after, ReaderBoundaryStatus.unavailable);

      final afterFailure = await launch.dataSource!.loadAround('c2');
      expect(afterFailure.after, ReaderBoundaryStatus.unavailable);

      final noNeighbor = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c1',
          direction: ReaderLoadDirection.before,
        ),
      );
      expect(noNeighbor.before, ReaderBoundaryStatus.endOfCatalog);
    },
  );
}

const _networkFailure = NoveliaGatewayException(
  NoveliaGatewayFailureKind.network,
  'offline',
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

CatalogNovel _novel(List<NovelChapter> chapters) {
  return CatalogNovel(
    id: 'syosetu/n8439ed',
    chineseTitle: '夜行列车',
    japaneseTitle: '夜の列車',
    author: '作者',
    source: 'Syosetu',
    publicationState: NovelPublicationState.ongoing,
    tags: const ['一般向'],
    translationCoverage: const [],
    readerNovel: ReaderNovel(
      id: 'syosetu/n8439ed',
      chineseTitle: '夜行列车',
      japaneseTitle: '夜の列車',
      author: '作者',
      chapters: chapters,
    ),
    declaredChapterCount: 4,
    chapterSections: const [
      CatalogChapterSection(title: '上卷', chapterIds: ['c1', 'c2']),
      CatalogChapterSection(title: '下卷', chapterIds: ['c3', 'c4']),
    ],
  );
}

NovelChapter _metadata(String id, int index) {
  return NovelChapter(
    id: id,
    index: index,
    chineseTitle: '$id-标题',
    japaneseTitle: '$id-title',
    publishedAt: DateTime.utc(2026, 8, index),
    blocks: const [],
  );
}

NovelChapter _loaded(NovelChapter metadata) {
  return NovelChapter(
    id: metadata.id,
    index: metadata.index,
    chineseTitle: metadata.chineseTitle,
    japaneseTitle: metadata.japaneseTitle,
    publishedAt: metadata.publishedAt,
    blocks: [
      AlignedBlock(
        id: '${metadata.id}:0',
        ordinal: 0,
        japanese: '本文',
        translations: const {TranslationSource.gpt: '正文'},
      ),
    ],
  );
}

class _WindowCoordinator
    implements NoveliaContentCoordinator, NoveliaChapterCacheReader {
  _WindowCoordinator(
    this.responses, {
    this.cachedResponses = const {},
    this.pendingResponses = const {},
  });

  final Map<String, NoveliaContentResult<NovelChapter>> responses;
  final Map<String, NovelChapter> cachedResponses;
  final Map<String, Completer<NoveliaContentResult<NovelChapter>>>
  pendingResponses;
  final List<String> chapterCalls = [];
  final List<TranslationSource> sources = [];

  @override
  NovelChapter? cachedChapter(
    CatalogNovel novel, {
    required String chapterId,
  }) => cachedResponses[chapterId];

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) async {
    chapterCalls.add(chapterId);
    sources.add(cacheTranslationSource);
    final pending = pendingResponses[chapterId];
    if (pending != null) return pending.future;
    return responses[chapterId] ??
        NoveliaContentResult.offline(failure: _networkFailure);
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) {
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
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(CatalogNovel outline) {
    throw UnimplementedError();
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) {
    throw UnimplementedError();
  }
}
