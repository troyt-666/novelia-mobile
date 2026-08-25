import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';

void main() {
  group('reader domain', () {
    test('reader appearance defaults preserve the v1 reading surface', () {
      const settings = ReaderSettings();

      expect(settings.layoutMode, ReaderLayoutMode.scroll);
      expect(settings.palette, ReaderPalette.automatic);
      expect(settings.fontFamily, ReaderFontFamily.systemSans);
      expect(settings.bodyBold, isFalse);
      expect(settings.paragraphSpacing, 15);
      expect(settings.pageMargin, 24);
      expect(settings.columnLayout, ReaderColumnLayout.automatic);
      expect(
        settings.orientationPreference,
        ReaderOrientationPreference.followDevice,
      );
      expect(settings.textSelectionEnabled, isTrue);
      expect(settings.tapPageTurnEnabled, isTrue);
    });

    test('reader settings copy all new layout and appearance fields', () {
      final settings = const ReaderSettings().copyWith(
        layoutMode: ReaderLayoutMode.pages,
        palette: ReaderPalette.sepia,
        fontFamily: ReaderFontFamily.systemSerif,
        bodyBold: true,
        paragraphSpacing: 20,
        pageMargin: 32,
        columnLayout: ReaderColumnLayout.twoColumns,
        orientationPreference: ReaderOrientationPreference.landscape,
        textSelectionEnabled: false,
        tapPageTurnEnabled: false,
      );

      expect(settings.layoutMode, ReaderLayoutMode.pages);
      expect(settings.palette, ReaderPalette.sepia);
      expect(settings.fontFamily, ReaderFontFamily.systemSerif);
      expect(settings.bodyBold, isTrue);
      expect(settings.paragraphSpacing, 20);
      expect(settings.pageMargin, 32);
      expect(settings.columnLayout, ReaderColumnLayout.twoColumns);
      expect(
        settings.orientationPreference,
        ReaderOrientationPreference.landscape,
      );
      expect(settings.textSelectionEnabled, isFalse);
      expect(settings.tapPageTurnEnabled, isFalse);
      expect(settings.translationSource, TranslationSource.sakura);
    });

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
