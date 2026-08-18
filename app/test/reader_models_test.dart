import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';

void main() {
  group('reader domain', () {
    test('stream preserves chapter boundaries and stable block order', () {
      final stream = fixtureNovel.buildStream();

      expect(stream.first, isA<ChapterBoundaryItem>());
      expect(stream[1], isA<AlignedBlockItem>());
      expect(stream[1].stableId, 'block:c1-0');
      expect(
        stream.whereType<ChapterBoundaryItem>().length,
        fixtureNovel.chapters.length,
      );
    });

    test('pending source is distinct from complete source', () {
      final pendingChapter = fixtureNovel.chapters[2];

      expect(
        pendingChapter.translationState(TranslationSource.sakura),
        TranslationState.pending,
      );
      expect(
        pendingChapter.translationState(TranslationSource.gpt),
        TranslationState.complete,
      );
    });

    test('partial chapter translation is invalid rather than guessed', () {
      final partialChapter = NovelChapter(
        id: 'partial',
        index: 1,
        chineseTitle: '测试',
        japaneseTitle: 'テスト',
        publishedAt: DateTime(2026, 1, 1),
        blocks: const [
          AlignedBlock(
            id: 'a',
            ordinal: 0,
            japanese: '一',
            translations: {TranslationSource.gpt: '一'},
          ),
          AlignedBlock(id: 'b', ordinal: 1, japanese: '二', translations: {}),
        ],
      );

      expect(
        partialChapter.translationState(TranslationSource.gpt),
        TranslationState.invalid,
      );
    });
  });
}
