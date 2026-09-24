import '../../core/offline/content_models.dart';
import '../../core/offline/content_repository.dart';
import 'novelia_domain_adapter.dart';

/// Retains a classification for online discovery without changing local access.
/// A service access change is never a request to delete device-local content.
void markRestrictedNovelForDiscovery(
  ContentRepository repository, {
  required String novelId,
  required DateTime checkedAt,
  required NoveliaDomainAdapter domainAdapter,
}) {
  try {
    final outline = repository
        .listCachedNovels(novelIds: [novelId])
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
  } on Object {
    // Metadata retention is best-effort; live access checks remain in force.
  }
}
