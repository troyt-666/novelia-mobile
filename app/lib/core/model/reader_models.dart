import 'package:flutter/foundation.dart';

enum ReadingMode {
  chineseOnly('仅中文'),
  chineseJapanese('中日对照');

  const ReadingMode(this.label);

  final String label;
}

enum ReaderLayoutMode { scroll, pages }

enum ReaderPalette { automatic, paper, sepia, lowLight, dark, black }

enum ReaderFontFamily { systemSans, systemSerif }

enum ReaderColumnLayout { automatic, singleColumn, twoColumns }

enum ReaderOrientationPreference { followDevice, portrait, landscape }

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
    this.layoutMode = ReaderLayoutMode.scroll,
    this.palette = ReaderPalette.automatic,
    this.fontFamily = ReaderFontFamily.systemSans,
    this.bodyBold = false,
    this.chineseFontSize = 22,
    this.japaneseFontSize = 16,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 15,
    this.japaneseOpacity = 0.56,
    this.pageMargin = 24,
    this.readingWidth = 720,
    this.columnLayout = ReaderColumnLayout.automatic,
    this.orientationPreference = ReaderOrientationPreference.followDevice,
    this.textSelectionEnabled = true,
    this.tapPageTurnEnabled = true,
  });

  final ReadingMode readingMode;
  final TranslationSource translationSource;
  final ReaderLayoutMode layoutMode;
  final ReaderPalette palette;
  final ReaderFontFamily fontFamily;
  final bool bodyBold;
  final double chineseFontSize;
  final double japaneseFontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double japaneseOpacity;
  final double pageMargin;
  final double readingWidth;
  final ReaderColumnLayout columnLayout;
  final ReaderOrientationPreference orientationPreference;
  final bool textSelectionEnabled;
  final bool tapPageTurnEnabled;

  ReaderSettings copyWith({
    ReadingMode? readingMode,
    TranslationSource? translationSource,
    ReaderLayoutMode? layoutMode,
    ReaderPalette? palette,
    ReaderFontFamily? fontFamily,
    bool? bodyBold,
    double? chineseFontSize,
    double? japaneseFontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? japaneseOpacity,
    double? pageMargin,
    double? readingWidth,
    ReaderColumnLayout? columnLayout,
    ReaderOrientationPreference? orientationPreference,
    bool? textSelectionEnabled,
    bool? tapPageTurnEnabled,
  }) {
    return ReaderSettings(
      readingMode: readingMode ?? this.readingMode,
      translationSource: translationSource ?? this.translationSource,
      layoutMode: layoutMode ?? this.layoutMode,
      palette: palette ?? this.palette,
      fontFamily: fontFamily ?? this.fontFamily,
      bodyBold: bodyBold ?? this.bodyBold,
      chineseFontSize: chineseFontSize ?? this.chineseFontSize,
      japaneseFontSize: japaneseFontSize ?? this.japaneseFontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      japaneseOpacity: japaneseOpacity ?? this.japaneseOpacity,
      pageMargin: pageMargin ?? this.pageMargin,
      readingWidth: readingWidth ?? this.readingWidth,
      columnLayout: columnLayout ?? this.columnLayout,
      orientationPreference:
          orientationPreference ?? this.orientationPreference,
      textSelectionEnabled: textSelectionEnabled ?? this.textSelectionEnabled,
      tapPageTurnEnabled: tapPageTurnEnabled ?? this.tapPageTurnEnabled,
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
  final List<ValueChanged<NovelChapter>> _chapterUpdateListeners = [];

  void addChapterUpdateListener(ValueChanged<NovelChapter> listener) {
    _chapterUpdateListeners.add(listener);
  }

  void removeChapterUpdateListener(ValueChanged<NovelChapter> listener) {
    _chapterUpdateListeners.remove(listener);
  }

  void notifyChapterUpdated(NovelChapter chapter) {
    for (final listener in List<ValueChanged<NovelChapter>>.of(
      _chapterUpdateListeners,
    )) {
      listener(chapter);
    }
  }
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

  @override
  bool operator ==(Object other) {
    return other is ReadingPosition &&
        other.chapterId == chapterId &&
        other.blockId == blockId &&
        other.intraBlockOffset == intraBlockOffset;
  }

  @override
  int get hashCode => Object.hash(chapterId, blockId, intraBlockOffset);
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
