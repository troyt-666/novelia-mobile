import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/features/discover/catalog_models.dart';
import 'package:novelia_reader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:novelia_reader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:novelia_reader/gateway/novelia/novelia_gateway.dart';
import 'package:novelia_reader/gateway/novelia/novelia_reader_window.dart';

void main() {
  test(
    'launches only requested target plus neighbors and preserves TOC order',
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

      expect(coordinator.chapterCalls, ['c2', 'c3', 'c4']);
      expect(coordinator.sources, everyElement(TranslationSource.gpt));
      expect(launch.novel.chapters.map((chapter) => chapter.id), [
        'c2',
        'c3',
        'c4',
      ]);
      expect(launch.initialPosition, same(requested));
      expect(launch.dataSource!.catalog.map((chapter) => chapter.id), [
        'c1',
        'c2',
        'c3',
        'c4',
      ]);
      expect(launch.dataSource!.catalog.first.sectionTitle, '上卷');
      expect(launch.dataSource!.catalog.last.sectionTitle, '下卷');

      final end = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c4',
          direction: ReaderLoadDirection.after,
        ),
      );
      expect(end.chapters, isEmpty);
      expect(end.after, ReaderBoundaryStatus.endOfCatalog);
      expect(coordinator.chapterCalls, ['c2', 'c3', 'c4']);

      final catalogLoad = await launch.dataSource!.loadAround('c1');
      expect(catalogLoad.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      expect(catalogLoad.before, ReaderBoundaryStatus.endOfCatalog);
      expect(catalogLoad.after, ReaderBoundaryStatus.loadable);
      expect(coordinator.chapterCalls, ['c2', 'c3', 'c4', 'c1']);
    },
  );

  test(
    'uses cached chapters and marks an offline missing neighbor unavailable',
    () async {
      final chapters = [
        _metadata('c1', 1),
        _metadata('c2', 2),
        _metadata('c3', 3),
      ];
      final coordinator = _WindowCoordinator({
        'c1': NoveliaContentResult.offline(cachedData: _loaded(chapters[0])),
        'c2': NoveliaContentResult.available(_loaded(chapters[1])),
        'c3': NoveliaContentResult.offline(failure: _networkFailure),
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

      expect(launch.novel.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      final around = await launch.dataSource!.loadAround('c2');
      expect(around.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      expect(around.before, ReaderBoundaryStatus.endOfCatalog);
      expect(around.after, ReaderBoundaryStatus.unavailable);

      final unavailable = await launch.dataSource!.loadAdjacent(
        const ReaderAdjacentRequest(
          anchorChapterId: 'c2',
          direction: ReaderLoadDirection.after,
        ),
      );
      expect(unavailable.chapters, isEmpty);
      expect(unavailable.after, ReaderBoundaryStatus.unavailable);

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

class _WindowCoordinator implements NoveliaContentCoordinator {
  _WindowCoordinator(this.responses);

  final Map<String, NoveliaContentResult<NovelChapter>> responses;
  final List<String> chapterCalls = [];
  final List<TranslationSource> sources = [];

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) async {
    chapterCalls.add(chapterId);
    sources.add(cacheTranslationSource);
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
