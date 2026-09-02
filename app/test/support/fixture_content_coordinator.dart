import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

class FixtureContentCoordinator implements NoveliaContentCoordinator {
  const FixtureContentCoordinator([this.novels = const []]);

  final List<CatalogNovel> novels;

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) async {
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(
        pageIndex: query.page,
        totalPages: novels.isEmpty ? 0 : 1,
        novels: novels,
      ),
    );
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) async {
    return NoveliaContentResult.available(
      NoveliaCatalogSlice(
        pageIndex: 0,
        totalPages: novels.isEmpty ? 0 : 1,
        novels: novels,
      ),
    );
  }

  @override
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(
    CatalogNovel outline,
  ) async {
    return NoveliaContentResult.available(_matchingNovel(outline));
  }

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) async {
    final chapter = _matchingNovel(
      novel,
    ).readerNovel?.chapters.where((item) => item.id == chapterId).firstOrNull;
    if (chapter == null) {
      throw StateError('Unknown fixture chapter $chapterId.');
    }
    return NoveliaContentResult.available(chapter);
  }

  @override
  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  }) async {
    final comments = _matchingNovel(novel).comments;
    return NoveliaContentResult.available(
      NoveliaCommentSlice(
        pageNumber: pageNumber,
        totalPages: comments.isEmpty ? 0 : 1,
        comments: comments,
      ),
    );
  }

  CatalogNovel _matchingNovel(CatalogNovel outline) {
    return novels.where((novel) => novel.id == outline.id).firstOrNull ??
        outline;
  }
}
