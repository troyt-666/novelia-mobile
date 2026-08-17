import 'dart:convert';

import '../../core/model/reader_models.dart';
import '../../core/offline/content_models.dart';
import '../../core/offline/offline_models.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_content_checksum.dart';
import 'novelia_domain_adapter.dart';
import 'novelia_gateway.dart';

/// Converts verified gateway content to and from the package-neutral cache.
class NoveliaContentCacheAdapter {
  const NoveliaContentCacheAdapter({
    this.domainAdapter = const NoveliaDomainAdapter(),
  });

  final NoveliaDomainAdapter domainAdapter;

  CachedNovelOutline cacheOutline(
    NoveliaNovelOutline outline, {
    required DateTime fetchedAt,
  }) {
    final mapped = domainAdapter.mapOutline(outline);
    return _cacheOutlineFromDomain(mapped, fetchedAt: fetchedAt);
  }

  CachedNovelDetail cacheDetails(
    NoveliaNovelDetails details, {
    required DateTime fetchedAt,
  }) {
    final mapped = domainAdapter.mapDetails(details);
    final readerNovel = mapped.readerNovel!;
    final chapterById = {
      for (final chapter in readerNovel.chapters) chapter.id: chapter,
    };

    return CachedNovelDetail(
      outline: _cacheOutlineFromDomain(mapped, fetchedAt: fetchedAt),
      synopsis: mapped.synopsis ?? '',
      points: mapped.points,
      views: mapped.views,
      originalUrl: mapped.originalUrl?.toString(),
      sections: [
        for (var index = 0; index < mapped.chapterSections.length; index++)
          CachedTocSection(
            id: '${mapped.id}:section:$index',
            title: mapped.chapterSections[index].title,
            chapters: [
              for (final chapterId in mapped.chapterSections[index].chapterIds)
                _cacheTocChapter(chapterById[chapterId]!),
            ],
          ),
      ],
    );
  }

  CachedChapterPayload cacheChapter(
    NoveliaChapterPayload payload, {
    required NovelChapter metadata,
    required DateTime fetchedAt,
  }) {
    if (payload.key.stableId.isEmpty || payload.chapterId != metadata.id) {
      throw const NoveliaDomainMappingException(
        'The chapter payload does not match its catalog entry.',
      );
    }
    final chineseTitle = payload.chineseTitle ?? metadata.chineseTitle;
    final revision = noveliaContentChecksum({
      'novelId': payload.key.stableId,
      'chapterId': payload.chapterId,
      'index': metadata.index,
      'chineseTitle': chineseTitle,
      'japaneseTitle': payload.japaneseTitle,
      'previousChapterId': payload.previousChapterId,
      'nextChapterId': payload.nextChapterId,
      'publishedAtUs': metadata.publishedAt?.microsecondsSinceEpoch,
      'japaneseBlocks': payload.originalParagraphs,
      'youdaoBlocks': payload.youdaoParagraphs,
      'gptBlocks': payload.gptParagraphs,
      'sakuraBlocks': payload.sakuraParagraphs,
    });
    return CachedChapterPayload(
      id: '${payload.key.stableId}::${payload.chapterId}::$revision',
      novelId: payload.key.stableId,
      chapterId: payload.chapterId,
      index: metadata.index,
      chineseTitle: chineseTitle,
      japaneseTitle: payload.japaneseTitle,
      previousChapterId: payload.previousChapterId,
      nextChapterId: payload.nextChapterId,
      publishedAt: metadata.publishedAt,
      japaneseBlocks: payload.originalParagraphs,
      translations: {
        TranslationSource.youdao: _cacheTranslation(
          payload.youdaoParagraphs,
          originalCount: payload.originalParagraphs.length,
        ),
        TranslationSource.gpt: _cacheTranslation(
          payload.gptParagraphs,
          originalCount: payload.originalParagraphs.length,
        ),
        TranslationSource.sakura: _cacheTranslation(
          payload.sakuraParagraphs,
          originalCount: payload.originalParagraphs.length,
        ),
      },
      fetchedAt: fetchedAt,
      revision: revision,
    );
  }

  OfflineChapterCopy cacheCopy(
    CachedChapterPayload payload, {
    required TranslationSource translationSource,
    required DateTime storedAt,
  }) {
    final translation = payload.translationFor(translationSource);
    return OfflineChapterCopy(
      id: [
        'cache',
        payload.novelId,
        payload.chapterId,
        translationSource.name,
      ].map(Uri.encodeComponent).join('::'),
      novelId: payload.novelId,
      chapterId: payload.chapterId,
      kind: OfflineCopyKind.cacheCopy,
      translationSource: translationSource,
      originalBytes: _utf8Length(payload.japaneseBlocks),
      translationBytes:
          translation?.availability == TranslationAvailability.complete
          ? _utf8Length(translation!.blocks)
          : null,
      storedAt: storedAt,
      payloadId: payload.id,
      revision: payload.revision,
      etag: payload.etag,
    );
  }

  OfflineChapterCopy downloadedCopy(
    CachedChapterPayload payload, {
    required DownloadTask task,
    required DateTime storedAt,
  }) {
    if (task.novelId != payload.novelId ||
        task.chapterId != payload.chapterId) {
      throw StateError('The downloaded payload does not match its task.');
    }
    final translation = payload.translationFor(task.translationSource);
    if (translation == null ||
        translation.availability == TranslationAvailability.invalid ||
        translation.availability == TranslationAvailability.unavailable) {
      throw StateError(
        'A protected download requires a complete or pending translation.',
      );
    }
    return OfflineChapterCopy(
      id: 'download:${task.id}:${payload.id}:${storedAt.microsecondsSinceEpoch}',
      novelId: payload.novelId,
      chapterId: payload.chapterId,
      kind: OfflineCopyKind.offlineDownload,
      translationSource: task.translationSource,
      originalBytes: _utf8Length(payload.japaneseBlocks),
      translationBytes:
          translation.availability == TranslationAvailability.complete
          ? _utf8Length(translation.blocks)
          : null,
      storedAt: storedAt,
      intentId: task.intentId,
      payloadId: payload.id,
      revision: payload.revision,
      etag: payload.etag,
    );
  }

  OfflineChapterCopy refreshedDownloadedCopy(
    CachedChapterPayload payload, {
    required OfflineChapterCopy existingCopy,
    required DateTime refreshedAt,
  }) {
    if (existingCopy.kind != OfflineCopyKind.offlineDownload ||
        existingCopy.novelId != payload.novelId ||
        existingCopy.chapterId != payload.chapterId) {
      throw StateError('The refreshed payload does not match its copy.');
    }
    final translation = payload.translationFor(existingCopy.translationSource);
    if (translation == null ||
        translation.availability == TranslationAvailability.unavailable) {
      throw StateError('The refreshed payload omits its selected source.');
    }
    return OfflineChapterCopy(
      id: existingCopy.id,
      novelId: existingCopy.novelId,
      chapterId: existingCopy.chapterId,
      kind: existingCopy.kind,
      translationSource: existingCopy.translationSource,
      originalBytes: _utf8Length(payload.japaneseBlocks),
      translationBytes:
          translation.availability == TranslationAvailability.complete
          ? _utf8Length(translation.blocks)
          : null,
      storedAt: refreshedAt,
      lastReadAt: existingCopy.lastReadAt,
      intentId: existingCopy.intentId,
      payloadId: payload.id,
      revision: payload.revision,
      etag: payload.etag,
    );
  }

  CatalogNovel restoreOutline(CachedNovelOutline outline) {
    _requireGeneralCache(outline);
    final key = _keyFor(outline.id);
    return CatalogNovel(
      id: outline.id,
      chineseTitle: outline.chineseTitle,
      japaneseTitle: outline.japaneseTitle,
      author: outline.author.isEmpty ? null : outline.author,
      source: domainAdapter.providerLabel(key.providerId),
      publicationState: _restorePublicationState(outline.publicationState),
      wordCount: outline.wordCount,
      updatedAt: outline.updatedAt,
      tags: outline.tags,
      translationCoverage: [
        for (final coverage in outline.translationCoverage)
          TranslationCoverage(
            source: coverage.source.label,
            translatedChapters: coverage.translatedChapters,
            totalChapters: coverage.totalChapters,
          ),
      ],
      declaredChapterCount: outline.chapterCount,
      originalUrl: domainAdapter.originalUri(key),
    );
  }

  /// Applies a fresh catalog outline without erasing fields that the outline
  /// DTO never carries but a previously fetched detail response did.
  CachedNovelOutline preserveDetailOnlyOutlineFields(
    CachedNovelOutline outline, {
    required CachedNovelOutline from,
  }) {
    if (outline.id != from.id) {
      throw StateError('Cannot merge cached metadata for different novels.');
    }
    return CachedNovelOutline(
      id: outline.id,
      chineseTitle: outline.chineseTitle,
      japaneseTitle: outline.japaneseTitle,
      author: from.author,
      contentSource: outline.contentSource,
      publicationState: outline.publicationState,
      chapterCount: outline.chapterCount,
      wordCount: from.wordCount,
      updatedAt: outline.updatedAt,
      tags: outline.tags,
      translationCoverage: outline.translationCoverage,
      fetchedAt: outline.fetchedAt,
      revision: outline.revision,
      etag: outline.etag,
    );
  }

  CatalogNovel restoreDetails(
    CachedNovelDetail detail, {
    List<NovelComment> comments = const [],
  }) {
    final outline = restoreOutline(detail.outline);
    final chapters = <NovelChapter>[];
    final sections = <CatalogChapterSection>[];
    for (final section in detail.sections) {
      final chapterIds = <String>[];
      for (final chapter in section.chapters) {
        chapters.add(
          NovelChapter(
            id: chapter.id,
            index: chapter.index,
            chineseTitle: chapter.chineseTitle,
            japaneseTitle: chapter.japaneseTitle,
            publishedAt: chapter.publishedAt,
            blocks: const [],
          ),
        );
        chapterIds.add(chapter.id);
      }
      sections.add(
        CatalogChapterSection(
          title: section.title,
          chapterIds: List.unmodifiable(chapterIds),
        ),
      );
    }

    final author = detail.outline.author;
    return CatalogNovel(
      id: outline.id,
      chineseTitle: outline.chineseTitle,
      japaneseTitle: outline.japaneseTitle,
      author: outline.author,
      source: outline.source,
      publicationState: outline.publicationState,
      wordCount: outline.wordCount,
      updatedAt: outline.updatedAt,
      tags: outline.tags,
      synopsis: detail.synopsis,
      points: detail.points,
      views: detail.views,
      translationCoverage: outline.translationCoverage,
      readerNovel: ReaderNovel(
        id: outline.id,
        chineseTitle: outline.chineseTitle,
        japaneseTitle: outline.japaneseTitle,
        author: author,
        chapters: chapters,
      ),
      declaredChapterCount: outline.declaredChapterCount,
      chapterSections: sections,
      comments: comments,
      originalUrl: outline.originalUrl,
    );
  }

  NovelChapter restoreChapter(CachedChapterPayload payload) {
    final states = <TranslationSource, TranslationState>{
      for (final source in TranslationSource.values)
        source: _restoreTranslationState(payload.translationFor(source)),
    };
    return NovelChapter(
      id: payload.chapterId,
      index: payload.index,
      chineseTitle: payload.chineseTitle,
      japaneseTitle: payload.japaneseTitle,
      publishedAt: payload.publishedAt,
      translationStates: states,
      blocks: [
        for (
          var ordinal = 0;
          ordinal < payload.japaneseBlocks.length;
          ordinal++
        )
          AlignedBlock(
            id: '${payload.chapterId}:$ordinal',
            ordinal: ordinal,
            japanese: payload.japaneseBlocks[ordinal],
            kind: _kindFor(payload.japaneseBlocks[ordinal]),
            translations: {
              for (final source in TranslationSource.values)
                if (states[source] == TranslationState.complete)
                  source: payload.translationFor(source)!.blocks[ordinal],
            },
          ),
      ],
    );
  }

  CachedNovelOutline _cacheOutlineFromDomain(
    CatalogNovel mapped, {
    required DateTime fetchedAt,
  }) {
    return CachedNovelOutline(
      id: mapped.id,
      chineseTitle: mapped.chineseTitle,
      japaneseTitle: mapped.japaneseTitle,
      author: mapped.author ?? '',
      contentSource: mapped.source,
      publicationState: _cachePublicationState(mapped.publicationState),
      chapterCount: mapped.declaredChapterCount,
      wordCount: mapped.wordCount,
      updatedAt: mapped.updatedAt,
      tags: mapped.tags,
      translationCoverage: [
        for (final coverage in mapped.translationCoverage)
          CachedTranslationCoverage(
            source: _sourceForLabel(coverage.source),
            translatedChapters: coverage.translatedChapters,
            totalChapters: coverage.totalChapters,
          ),
      ],
      fetchedAt: fetchedAt,
    );
  }

  static CachedTocChapter _cacheTocChapter(NovelChapter chapter) {
    return CachedTocChapter(
      id: chapter.id,
      index: chapter.index,
      chineseTitle: chapter.chineseTitle,
      japaneseTitle: chapter.japaneseTitle,
      publishedAt: chapter.publishedAt,
    );
  }

  static CachedChapterTranslation _cacheTranslation(
    List<String> blocks, {
    required int originalCount,
  }) {
    final availability = blocks.isEmpty
        ? TranslationAvailability.pending
        : blocks.length == originalCount
        ? TranslationAvailability.complete
        : TranslationAvailability.invalid;
    return CachedChapterTranslation(availability: availability, blocks: blocks);
  }

  static TranslationState _restoreTranslationState(
    CachedChapterTranslation? translation,
  ) {
    return switch (translation?.availability) {
      TranslationAvailability.complete => TranslationState.complete,
      TranslationAvailability.invalid => TranslationState.invalid,
      TranslationAvailability.pending ||
      TranslationAvailability.unavailable ||
      null => TranslationState.pending,
    };
  }

  static CachedNovelState _cachePublicationState(NovelPublicationState state) {
    return switch (state) {
      NovelPublicationState.ongoing => CachedNovelState.ongoing,
      NovelPublicationState.completed => CachedNovelState.completed,
      NovelPublicationState.shortStory => CachedNovelState.shortStory,
      NovelPublicationState.unknown => CachedNovelState.unknown,
    };
  }

  static NovelPublicationState _restorePublicationState(
    CachedNovelState state,
  ) {
    return switch (state) {
      CachedNovelState.ongoing => NovelPublicationState.ongoing,
      CachedNovelState.completed => NovelPublicationState.completed,
      CachedNovelState.shortStory => NovelPublicationState.shortStory,
      CachedNovelState.unknown => NovelPublicationState.unknown,
    };
  }

  static TranslationSource _sourceForLabel(String label) {
    for (final source in TranslationSource.values) {
      if (source.label == label) return source;
    }
    throw NoveliaDomainMappingException(
      'Unsupported cached translation source: $label.',
    );
  }

  NoveliaNovelKey _keyFor(String stableId) {
    return domainAdapter.keyFromStableId(stableId) ??
        (throw NoveliaDomainMappingException(
          'Invalid cached Novelia ID: $stableId.',
        ));
  }

  void _requireGeneralCache(CachedNovelOutline outline) {
    if (domainAdapter.isRestrictedAttentions(outline.tags)) {
      throw NoveliaRestrictedContentException(
        'Restricted cached novel ${outline.id} was rejected.',
      );
    }
  }

  static int _utf8Length(Iterable<String> blocks) {
    return blocks.fold<int>(
      0,
      (total, block) => total + utf8.encode(block).length,
    );
  }

  static AlignedBlockKind _kindFor(String original) {
    if (original.isEmpty) return AlignedBlockKind.separator;
    final trimmed = original.trimLeft();
    if (trimmed.startsWith('「') ||
        trimmed.startsWith('『') ||
        trimmed.startsWith('“')) {
      return AlignedBlockKind.dialogue;
    }
    return AlignedBlockKind.paragraph;
  }
}
