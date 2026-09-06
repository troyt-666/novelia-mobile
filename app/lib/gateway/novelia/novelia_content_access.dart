import '../../core/offline/content_models.dart';
import '../../core/offline/content_repository.dart';
import 'novelia_domain_adapter.dart';

/// Marks retained download metadata before evicting expendable restricted data.
/// Reading and download paths use the same cleanup; protected copies survive.
void revokeRestrictedNovelCache(
  ContentRepository repository, {
  required String novelId,
  required DateTime checkedAt,
  required NoveliaDomainAdapter domainAdapter,
}) {
  try {
    final outline = repository
        .listCachedNovels()
        .where((outline) => outline.id == novelId)
        .firstOrNull;
    if (outline != null &&
        !domainAdapter.isRestrictedAttentions(outline.tags)) {
      repository.upsertNovelOutline(
        CachedNovelOutline(
          id: outline.id,
          chineseTitle: outline.chineseTitle,
          japaneseTitle: outline.japaneseTitle,
          author: outline.author,
          contentSource: outline.contentSource,
          publicationState: outline.publicationState,
          chapterCount: outline.chapterCount,
          wordCount: outline.wordCount,
          updatedAt: outline.updatedAt,
          tags: [...outline.tags, 'R18'],
          translationCoverage: outline.translationCoverage,
          fetchedAt: checkedAt,
          revision: outline.revision,
          etag: outline.etag,
        ),
      );
    }
    repository.removeCachedNovel(novelId);
  } on Object {
    // Cleanup is best-effort; the caller still denies the current operation.
  }
}
