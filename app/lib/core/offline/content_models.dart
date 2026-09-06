import '../model/reader_models.dart';

enum CachedNovelState { ongoing, completed, shortStory, unknown }

enum TranslationAvailability { complete, pending, invalid, unavailable }

class CachedTranslationCoverage {
  CachedTranslationCoverage({
    required this.source,
    required this.translatedChapters,
    required this.totalChapters,
  }) {
    if ((translatedChapters != null && translatedChapters! < 0) ||
        (totalChapters != null && totalChapters! < 0) ||
        (translatedChapters != null &&
            totalChapters != null &&
            translatedChapters! > totalChapters!)) {
      throw ArgumentError('Translation coverage counts are inconsistent.');
    }
  }

  final TranslationSource source;
  final int? translatedChapters;
  final int? totalChapters;
}

/// Provider-neutral metadata sufficient to render a cached discovery card.
///
/// User-visible strings are retained exactly, including empty strings. Only
/// stable identity fields are required to be non-empty.
class CachedNovelOutline {
  CachedNovelOutline({
    required this.id,
    required this.chineseTitle,
    required this.japaneseTitle,
    required this.author,
    required this.contentSource,
    required this.publicationState,
    required this.chapterCount,
    required this.wordCount,
    required this.updatedAt,
    required List<String> tags,
    required List<CachedTranslationCoverage> translationCoverage,
    required this.fetchedAt,
    this.revision,
    this.etag,
  }) : tags = List.unmodifiable(tags),
       translationCoverage = List.unmodifiable(translationCoverage) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    if (wordCount != null && wordCount! < 0) {
      throw ArgumentError.value(wordCount, 'wordCount');
    }
    if (chapterCount != null && chapterCount! < 0) {
      throw ArgumentError.value(chapterCount, 'chapterCount');
    }
    final sources = <TranslationSource>{};
    for (final coverage in translationCoverage) {
      if (!sources.add(coverage.source)) {
        throw ArgumentError(
          'Translation coverage repeats ${coverage.source.name}.',
        );
      }
    }
  }

  final String id;
  final String chineseTitle;
  final String japaneseTitle;
  final String author;
  final String contentSource;
  final CachedNovelState publicationState;
  final int? chapterCount;
  final int? wordCount;
  final DateTime? updatedAt;
  final List<String> tags;
  final List<CachedTranslationCoverage> translationCoverage;
  final DateTime fetchedAt;
  final String? revision;
  final String? etag;
}

class CachedTocChapter {
  CachedTocChapter({
    required this.id,
    required this.index,
    required this.chineseTitle,
    required this.japaneseTitle,
    this.publishedAt,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    if (index < 0) throw ArgumentError.value(index, 'index');
  }

  final String id;
  final int index;
  final String chineseTitle;
  final String japaneseTitle;
  final DateTime? publishedAt;
}

class CachedTocSection {
  CachedTocSection({
    required this.id,
    required this.title,
    required List<CachedTocChapter> chapters,
  }) : chapters = List.unmodifiable(chapters) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    final chapterIds = <String>{};
    for (final chapter in chapters) {
      if (!chapterIds.add(chapter.id)) {
        throw ArgumentError('Section $id repeats chapter ${chapter.id}.');
      }
    }
  }

  final String id;
  final String title;
  final List<CachedTocChapter> chapters;
}

/// Full cached Novel Details data, including ordered sections and chapters.
class CachedNovelDetail {
  CachedNovelDetail({
    required this.outline,
    required this.synopsis,
    required this.points,
    required this.views,
    required this.originalUrl,
    required List<CachedTocSection> sections,
  }) : sections = List.unmodifiable(sections) {
    if (points != null && points! < 0) {
      throw ArgumentError.value(points, 'points');
    }
    if (views != null && views! < 0) {
      throw ArgumentError.value(views, 'views');
    }
    final sectionIds = <String>{};
    final chapterIds = <String>{};
    for (final section in sections) {
      if (!sectionIds.add(section.id)) {
        throw ArgumentError('Novel repeats section ${section.id}.');
      }
      for (final chapter in section.chapters) {
        if (!chapterIds.add(chapter.id)) {
          throw ArgumentError('Novel repeats chapter ${chapter.id}.');
        }
      }
    }
  }

  final CachedNovelOutline outline;
  final String synopsis;
  final int? points;
  final int? views;
  final String? originalUrl;
  final List<CachedTocSection> sections;
}

class CachedChapterTranslation {
  CachedChapterTranslation({
    required this.availability,
    required List<String> blocks,
  }) : blocks = List.unmodifiable(blocks) {
    if ((availability == TranslationAvailability.pending ||
            availability == TranslationAvailability.unavailable) &&
        blocks.isNotEmpty) {
      throw ArgumentError(
        '${availability.name} translations cannot contain translated blocks.',
      );
    }
  }

  final TranslationAvailability availability;
  final List<String> blocks;
}

/// One coherent fetched chapter revision with exact source arrays.
class CachedChapterPayload {
  CachedChapterPayload({
    required this.id,
    required this.novelId,
    required this.chapterId,
    required this.index,
    required this.chineseTitle,
    required this.japaneseTitle,
    required this.previousChapterId,
    required this.nextChapterId,
    required this.publishedAt,
    required List<String> japaneseBlocks,
    required Map<TranslationSource, CachedChapterTranslation> translations,
    required this.fetchedAt,
    this.revision,
    this.etag,
  }) : japaneseBlocks = List.unmodifiable(japaneseBlocks),
       translations = Map.unmodifiable(translations) {
    if (id.isEmpty || novelId.isEmpty || chapterId.isEmpty) {
      throw ArgumentError('Payload, novel, and chapter IDs must be non-empty.');
    }
    if (index < 0) throw ArgumentError.value(index, 'index');
    for (final entry in translations.entries) {
      if (entry.value.availability == TranslationAvailability.complete &&
          entry.value.blocks.length != japaneseBlocks.length) {
        throw ArgumentError(
          'Complete ${entry.key.name} translation block count does not match '
          'the Japanese original.',
        );
      }
    }
  }

  final String id;
  final String novelId;
  final String chapterId;
  final int index;
  final String chineseTitle;
  final String japaneseTitle;
  final String? previousChapterId;
  final String? nextChapterId;
  final DateTime? publishedAt;
  final List<String> japaneseBlocks;
  final Map<TranslationSource, CachedChapterTranslation> translations;
  final DateTime fetchedAt;
  final String? revision;
  final String? etag;

  CachedChapterTranslation? translationFor(TranslationSource source) {
    return translations[source];
  }
}
