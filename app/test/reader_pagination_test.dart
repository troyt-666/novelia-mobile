import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/reader/reader_body.dart';
import 'package:jfzreader/features/reader/reader_pagination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final state in [TranslationState.complete, TranslationState.pending]) {
    testWidgets('pagination fits the rendered chapter header: ${state.name}', (
      tester,
    ) async {
      final block = _item('これは原文です。', chinese: '这是正文。').block;
      final chapter = NovelChapter(
        id: 'chapter',
        index: 1,
        chineseTitle: '章节标题',
        japaneseTitle: '章のタイトル',
        publishedAt: DateTime(2026),
        blocks: [block],
        translationStates: {TranslationSource.sakura: state},
      );
      final header = ChapterBoundaryItem(chapter: chapter);
      final body = AlignedBlockItem(chapter: chapter, block: block);
      const settings = ReaderSettings();
      const inheritedStyle = TextStyle(
        fontSize: 16,
        height: 1.8,
        letterSpacing: .4,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: DefaultTextStyle(
                style: inheritedStyle,
                child: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReaderChapterBoundary(
                        item: header,
                        itemKey: GlobalKey(),
                        settings: settings,
                        foreground: Colors.black,
                      ),
                      ReaderAlignedBlockView(
                        item: body,
                        settings: settings,
                        foreground: Colors.black,
                        bookmarked: false,
                        onMounted: (_) {},
                        onUnmounted: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final actualHeight =
          tester.getSize(find.byType(ReaderChapterBoundary)).height +
          tester.getSize(find.byType(ReaderAlignedBlockView)).height;
      final pagination = ReaderPagination.compose(
        items: [header, body],
        settings: settings,
        textScaler: TextScaler.noScaling,
        baseTextStyle: inheritedStyle,
        viewportWidth: 430,
        availableHeight: actualHeight - 1,
      );
      expect(
        pagination.pages,
        hasLength(2),
        reason: 'A header and body taller than the page must not share it.',
      );
    });
  }

  for (final width in [430.0, 1100.0]) {
    test('pagination preserves bilingual text and anchors at width $width', () {
      final japanese = List.filled(80, '原文😀。').join();
      final chinese = List.filled(80, '译文🌸。').join();
      final item = _item(japanese, chinese: chinese);
      final pagination = ReaderPagination.compose(
        items: [
          null,
          ChapterBoundaryItem(chapter: item.chapter),
          item,
          null,
        ],
        settings: const ReaderSettings(readingWidth: 1100),
        textScaler: TextScaler.noScaling,
        viewportWidth: width,
        availableHeight: 200,
      );
      final fragments = pagination.pages
          .expand((page) => page.entries)
          .map((entry) => entry.fragment)
          .whereType<ReaderTextFragment>()
          .toList();
      expect(fragments.length, greaterThan(1));
      expect(fragments.map((part) => part.chinese ?? '').join(), chinese);
      expect(fragments.map((part) => part.japanese ?? '').join(), japanese);
      for (var index = 0; index < pagination.pages.length; index++) {
        for (final entry in pagination.pages[index].entries) {
          final fragment = entry.fragment;
          if (fragment == null) continue;
          expect(
            pagination.pageForStableId(
              item.stableId,
              fragment.intraBlockOffset,
            ),
            index,
          );
        }
      }
      expect(pagination.pageForStableId('missing', 0), isNull);
    });
  }

  test('oversized emoji advances without splitting its surrogate pair', () {
    // At this text scale a single glyph exceeds the page's text height.
    // The old binary search repeated its bounds when a midpoint split an emoji.
    final item = _item('😀😀🌸');
    final pagination = ReaderPagination.compose(
      items: [item],
      settings: const ReaderSettings(chineseFontSize: 32),
      textScaler: TextScaler.linear(3),
      viewportWidth: 120,
      availableHeight: 120,
    );
    final fragments = pagination.pages
        .expand((page) => page.entries)
        .map((entry) => entry.fragment!.japanese!)
        .toList();
    expect(fragments.join(), item.block.japanese);
    expect(fragments.length, greaterThan(1));
    for (final text in fragments) {
      expect(
        text.runes.any((rune) => rune >= 0xD800 && rune <= 0xDFFF),
        isFalse,
      );
    }
  });

  test('unavailable translation paginates the full Japanese original', () {
    final original = List.filled(80, '原文。').join();
    final pagination = ReaderPagination.compose(
      items: [_item(original)],
      settings: const ReaderSettings(readingMode: ReadingMode.chineseOnly),
      textScaler: TextScaler.noScaling,
      viewportWidth: 430,
      availableHeight: 200,
    );
    final fragments = pagination.pages
        .expand((page) => page.entries)
        .map((entry) => entry.fragment!)
        .toList();
    expect(fragments.map((part) => part.japanese).join(), original);
    expect(fragments.every((part) => part.chinese == null), isTrue);
  });
}

AlignedBlockItem _item(String japanese, {String? chinese}) {
  final block = AlignedBlock(
    id: 'block',
    ordinal: 0,
    japanese: japanese,
    translations: {TranslationSource.sakura: ?chinese},
  );
  return AlignedBlockItem(
    chapter: NovelChapter(
      id: 'chapter',
      index: 1,
      chineseTitle: '章节',
      japaneseTitle: '章',
      publishedAt: null,
      blocks: [block],
    ),
    block: block,
  );
}
