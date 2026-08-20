import '../../core/model/reader_models.dart';
import 'novelia_gateway.dart';

/// Converts verified gateway payloads into the package-neutral reader model.
///
/// Translation arrays are accepted only when their count exactly matches the
/// Japanese Original. A mismatch marks the complete source revision invalid;
/// no partial translation is exposed to the reader.
class NoveliaReaderAdapter {
  const NoveliaReaderAdapter();

  ReaderNovel buildNovel({
    required NoveliaNovelDetails details,
    required Iterable<NoveliaChapterPayload> chapters,
  }) {
    final payloadById = {
      for (final chapter in chapters) chapter.chapterId: chapter,
    };
    final tocById = {for (final entry in details.toc) ?entry.chapterId: entry};
    final orderedIds = <String>[
      for (final entry in details.toc)
        if (entry.chapterId case final chapterId?)
          if (payloadById.containsKey(chapterId)) chapterId,
      for (final chapterId in payloadById.keys)
        if (!tocById.containsKey(chapterId)) chapterId,
    ];

    return ReaderNovel(
      id: details.key.stableId,
      chineseTitle: details.chineseTitle ?? details.japaneseTitle,
      japaneseTitle: details.japaneseTitle,
      author: details.authors.map((author) => author.name).join('、'),
      chapters: [
        for (var index = 0; index < orderedIds.length; index++)
          _buildChapter(
            payloadById[orderedIds[index]]!,
            tocById[orderedIds[index]],
            index + 1,
          ),
      ],
    );
  }

  NovelChapter buildSingleChapter({
    required NoveliaChapterPayload payload,
    NoveliaTocEntry? tocEntry,
    int index = 1,
  }) => _buildChapter(payload, tocEntry, index);

  NovelChapter _buildChapter(
    NoveliaChapterPayload payload,
    NoveliaTocEntry? tocEntry,
    int index,
  ) {
    final sourceParagraphs = <TranslationSource, List<String>>{
      TranslationSource.youdao: payload.youdaoParagraphs,
      TranslationSource.gpt: payload.gptParagraphs,
      TranslationSource.sakura: payload.sakuraParagraphs,
    };
    final states = <TranslationSource, TranslationState>{
      for (final entry in sourceParagraphs.entries)
        entry.key: _stateFor(
          originalCount: payload.originalParagraphs.length,
          translatedCount: entry.value.length,
        ),
    };

    return NovelChapter(
      id: payload.chapterId,
      index: index,
      chineseTitle:
          payload.chineseTitle ??
          tocEntry?.chineseTitle ??
          payload.japaneseTitle,
      japaneseTitle: payload.japaneseTitle,
      publishedAt: tocEntry?.createdAt,
      translationStates: states,
      blocks: [
        for (
          var ordinal = 0;
          ordinal < payload.originalParagraphs.length;
          ordinal++
        )
          AlignedBlock(
            id: '${payload.chapterId}:$ordinal',
            ordinal: ordinal,
            japanese: payload.originalParagraphs[ordinal],
            kind: _kindFor(payload.originalParagraphs[ordinal]),
            translations: {
              for (final entry in sourceParagraphs.entries)
                if (states[entry.key] == TranslationState.complete)
                  entry.key: entry.value[ordinal],
            },
          ),
      ],
    );
  }

  static TranslationState _stateFor({
    required int originalCount,
    required int translatedCount,
  }) {
    if (translatedCount == 0) return TranslationState.pending;
    if (translatedCount != originalCount) return TranslationState.invalid;
    return TranslationState.complete;
  }

  static AlignedBlockKind _kindFor(String original) {
    if (original.isEmpty) return AlignedBlockKind.separator;
    final trimmed = original.trimLeft();
    if (trimmed.startsWith(AlignedBlock.illustrationPrefix)) {
      return AlignedBlockKind.illustration;
    }
    if (trimmed.startsWith('「') ||
        trimmed.startsWith('『') ||
        trimmed.startsWith('“')) {
      return AlignedBlockKind.dialogue;
    }
    return AlignedBlockKind.paragraph;
  }
}
