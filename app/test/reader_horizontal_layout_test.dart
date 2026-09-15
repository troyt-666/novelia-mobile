import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/reader/reader_screen.dart';

void main() => runHorizontalLayoutTests();

void runHorizontalLayoutTests({
  bool useDeviceViewport = false,
  Future<void> Function(WidgetTester tester, double scale)? onSamplePage,
}) {
  for (final scale in [1.0, 1.6]) {
    testWidgets('every horizontal page paints all its text at scale $scale', (
      tester,
    ) async {
      if (!useDeviceViewport) {
        tester.view.physicalSize = const Size(430, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final blocks = [
        for (var n = 0; n < 8; n++)
          AlignedBlock(
            id: 'layout-$n',
            ordinal: n,
            japanese: n == 1
                ? ''
                : List.filled(n == 2 ? 100 : 3, '原文$n。「窓の外に、桜が咲いていた。」').join(),
            translations: {
              TranslationSource.sakura: List.filled(
                n == 2 ? 100 : 3,
                '正文$n。「窗外，樱花正在盛开。」',
              ).join(),
            },
          ),
      ];
      final novel = ReaderNovel(
        id: 'horizontal-layout',
        chineseTitle: '横向分页验证',
        japaneseTitle: 'ページ検証',
        author: '虚构作者',
        chapters: [
          NovelChapter(
            id: 'layout-chapter',
            index: 1,
            chineseTitle: '逐页检查正文完整性',
            japaneseTitle: '本文の表示を検証する',
            publishedAt: null,
            blocks: blocks,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamilyFallback: const [
              'PingFang SC',
              'Noto Sans CJK SC',
              'Hiragino Sans',
            ],
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ReaderScreen(
            novel: novel,
            themeMode: ThemeMode.light,
            onThemeModeChanged: (_) {},
            initialSettings: const ReaderSettings(
              layoutMode: ReaderLayoutMode.pages,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pageView = tester.widget<PageView>(find.byType(PageView));
      final controller = pageView.controller!;
      final pageCount = pageView.childrenDelegate.estimatedChildCount!;
      final painted = <String, String>{};
      for (var page = 0; page < pageCount; page++) {
        controller.jumpToPage(page);
        await tester.pumpAndSettle();
        if (page == 2) await onSamplePage?.call(tester, scale);
        final pageFinder = find.byKey(ValueKey('reader-horizontal-page-$page'));
        final bounds = tester.getRect(pageFinder);
        final texts = find.descendant(
          of: pageFinder,
          matching: find.byType(Text),
        );
        for (final element in texts.evaluate()) {
          final widget = element.widget as Text;
          final key = widget.key;
          if (key is! ValueKey<String> ||
              !key.value.startsWith('block-layout-')) {
            continue;
          }
          final box = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byWidget(widget),
              matching: find.byType(RichText),
            ),
          );
          final rect = MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          );
          expect(
            rect.bottom,
            lessThanOrEqualTo(bounds.bottom + .01),
            reason: 'Page $page clips ${key.value}: $rect outside $bounds',
          );
          expect(box.didExceedMaxLines, isFalse);
          final textBoxes = box.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: widget.data!.length),
          );
          for (final textBox in textBoxes) {
            expect(
              box.localToGlobal(Offset(0, textBox.bottom)).dy,
              lessThanOrEqualTo(bounds.bottom + .01),
              reason: 'Page $page clips the last line of ${key.value}',
            );
          }
          final languageKey = key.value.split('-fragment-').first;
          painted.update(
            languageKey,
            (text) => text + widget.data!,
            ifAbsent: () => widget.data!,
          );
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'Page $page must fit its viewport',
        );
      }
      for (final block in blocks) {
        expect(
          painted['block-${block.id}-chinese'],
          block.translationFor(TranslationSource.sakura),
        );
        expect(painted['block-${block.id}-japanese'], block.japanese);
      }
    });
  }
}
