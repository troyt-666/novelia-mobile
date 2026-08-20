import 'package:flutter/foundation.dart';

enum ReadingMode {
  chineseOnly('仅中文'),
  chineseJapanese('中日对照');

  const ReadingMode(this.label);

  final String label;
}

enum TranslationSource {
  youdao('有道'),
  gpt('GPT'),
  sakura('Sakura');

  const TranslationSource(this.label);

  final String label;
}

enum TranslationState { complete, pending, invalid }

enum AlignedBlockKind { heading, paragraph, dialogue, separator, illustration }

@immutable
class ReaderSettings {
  const ReaderSettings({
    this.readingMode = ReadingMode.chineseJapanese,
    this.translationSource = TranslationSource.sakura,
    this.chineseFontSize = 22,
    this.japaneseFontSize = 16,
    this.lineHeight = 1.8,
    this.japaneseOpacity = 0.56,
    this.readingWidth = 720,
  });

  final ReadingMode readingMode;
  final TranslationSource translationSource;
  final double chineseFontSize;
  final double japaneseFontSize;
  final double lineHeight;
  final double japaneseOpacity;
  final double readingWidth;

  ReaderSettings copyWith({
    ReadingMode? readingMode,
    TranslationSource? translationSource,
    double? chineseFontSize,
    double? japaneseFontSize,
    double? lineHeight,
    double? japaneseOpacity,
    double? readingWidth,
  }) {
    return ReaderSettings(
      readingMode: readingMode ?? this.readingMode,
      translationSource: translationSource ?? this.translationSource,
      chineseFontSize: chineseFontSize ?? this.chineseFontSize,
      japaneseFontSize: japaneseFontSize ?? this.japaneseFontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      japaneseOpacity: japaneseOpacity ?? this.japaneseOpacity,
      readingWidth: readingWidth ?? this.readingWidth,
    );
  }
}

@immutable
class AlignedBlock {
  static const illustrationPrefix = '<图片>';

  const AlignedBlock({
    required this.id,
    required this.ordinal,
    required this.japanese,
    required this.translations,
    this.kind = AlignedBlockKind.paragraph,
  });

  final String id;
  final int ordinal;
  final String japanese;
  final Map<TranslationSource, String> translations;
  final AlignedBlockKind kind;

  /// The service normalizes provider-specific illustration markup to
  /// `<图片>https://…`. Keep the transport marker out of presentation code and
  /// reject non-Web schemes before handing the URI to an image widget.
  Uri? get illustrationUri {
    if (kind != AlignedBlockKind.illustration) return null;
    final value = japanese.trimLeft();
    if (!value.startsWith(illustrationPrefix)) return null;
    final uri = Uri.tryParse(value.substring(illustrationPrefix.length).trim());
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return uri;
  }

  String? translationFor(TranslationSource source) {
    final value = translations[source]?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

@immutable
class NovelChapter {
  const NovelChapter({
    required this.id,
    required this.index,
    required this.chineseTitle,
    required this.japaneseTitle,
    required this.publishedAt,
    required this.blocks,
    this.translationStates = const {},
  });

  final String id;
  final int index;
  final String chineseTitle;
  final String japaneseTitle;
  final DateTime? publishedAt;
  final List<AlignedBlock> blocks;
  final Map<TranslationSource, TranslationState> translationStates;

  TranslationState translationState(TranslationSource source) {
    final explicitState = translationStates[source];
    if (explicitState != null) return explicitState;
    final translatedCount = blocks
        .where((block) => block.translationFor(source) != null)
        .length;
    if (translatedCount == 0) {
      return TranslationState.pending;
    }
    if (translatedCount != blocks.length) {
      return TranslationState.invalid;
    }
    return TranslationState.complete;
  }
}

@immutable
class ReaderNovel {
  const ReaderNovel({
    required this.id,
    required this.chineseTitle,
    required this.japaneseTitle,
    required this.author,
    required this.chapters,
  });

  final String id;
  final String chineseTitle;
  final String japaneseTitle;
  final String author;
  final List<NovelChapter> chapters;

  List<ReaderStreamItem> buildStream() {
    return [
      for (final chapter in chapters) ...[
        ChapterBoundaryItem(chapter: chapter),
        for (final block in chapter.blocks)
          AlignedBlockItem(chapter: chapter, block: block),
      ],
    ];
  }
}

enum ReaderLoadDirection { before, after }

/// Describes whether content beyond one side of a loaded chapter window can be
/// requested. `unavailable` is a normal local/offline boundary, not an error.
enum ReaderBoundaryStatus { loadable, endOfCatalog, unavailable }

@immutable
class ReaderChapterCatalogEntry {
  const ReaderChapterCatalogEntry({
    required this.id,
    required this.index,
    required this.chineseTitle,
    required this.japaneseTitle,
    this.publishedAt,
    this.sectionTitle,
  });

  factory ReaderChapterCatalogEntry.fromChapter(
    NovelChapter chapter, {
    String? sectionTitle,
  }) {
    return ReaderChapterCatalogEntry(
      id: chapter.id,
      index: chapter.index,
      chineseTitle: chapter.chineseTitle,
      japaneseTitle: chapter.japaneseTitle,
      publishedAt: chapter.publishedAt,
      sectionTitle: sectionTitle,
    );
  }

  final String id;
  final int index;
  final String chineseTitle;
  final String japaneseTitle;
  final DateTime? publishedAt;
  final String? sectionTitle;
}

@immutable
class ReaderAdjacentRequest {
  const ReaderAdjacentRequest({
    required this.anchorChapterId,
    required this.direction,
  });

  final String anchorChapterId;
  final ReaderLoadDirection direction;
}

@immutable
class ReaderChapterWindow {
  const ReaderChapterWindow({
    required this.chapters,
    required this.before,
    required this.after,
  });

  final List<NovelChapter> chapters;
  final ReaderBoundaryStatus before;
  final ReaderBoundaryStatus after;
}

typedef ReaderLoadAround =
    Future<ReaderChapterWindow> Function(String chapterId);
typedef ReaderLoadAdjacent =
    Future<ReaderChapterWindow> Function(ReaderAdjacentRequest request);

/// Package-neutral reader data source. The catalog contains metadata for the
/// entire novel while loaders return only bounded chapter-body windows.
class ReaderChapterDataSource {
  ReaderChapterDataSource({
    required List<ReaderChapterCatalogEntry> catalog,
    required this.loadAround,
    required this.loadAdjacent,
  }) : catalog = List.unmodifiable(catalog) {
    final ids = <String>{};
    for (final chapter in this.catalog) {
      if (chapter.id.isEmpty || !ids.add(chapter.id)) {
        throw ArgumentError.value(
          chapter.id,
          'catalog',
          'Chapter IDs must be non-empty and unique.',
        );
      }
    }
  }

  final List<ReaderChapterCatalogEntry> catalog;
  final ReaderLoadAround loadAround;
  final ReaderLoadAdjacent loadAdjacent;
}

@immutable
class ReadingPosition {
  const ReadingPosition({
    required this.chapterId,
    required this.blockId,
    this.intraBlockOffset = 0,
  });

  final String chapterId;
  final String blockId;
  final int intraBlockOffset;
}

sealed class ReaderStreamItem {
  const ReaderStreamItem({required this.chapter});

  final NovelChapter chapter;
  String get stableId;
}

final class ChapterBoundaryItem extends ReaderStreamItem {
  const ChapterBoundaryItem({required super.chapter});

  @override
  String get stableId => 'chapter:${chapter.id}';
}

final class AlignedBlockItem extends ReaderStreamItem {
  const AlignedBlockItem({required super.chapter, required this.block});

  final AlignedBlock block;

  @override
  String get stableId => 'block:${block.id}';
}
