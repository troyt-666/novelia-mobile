import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/reader/reader_body.dart';
import 'package:jfzreader/features/reader/reader_screen.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';

void _expectReaderKeyboardMapping() {
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowUp,
      ReaderLayoutMode.scroll,
    ),
    ReaderLoadDirection.before,
  );
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowDown,
      ReaderLayoutMode.scroll,
    ),
    ReaderLoadDirection.after,
  );
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowLeft,
      ReaderLayoutMode.pages,
    ),
    ReaderLoadDirection.before,
  );
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowRight,
      ReaderLayoutMode.pages,
    ),
    ReaderLoadDirection.after,
  );
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowLeft,
      ReaderLayoutMode.scroll,
    ),
    isNull,
  );
  expect(
    readerNavigationDirectionForKey(
      LogicalKeyboardKey.arrowDown,
      ReaderLayoutMode.pages,
    ),
    isNull,
  );
}

NovelChapter _windowChapter(
  int number, {
  int blockCount = 6,
  int paragraphRepeats = 4,
}) {
  return NovelChapter(
    id: 'window-c$number',
    index: number,
    chineseTitle: '窗口章节 $number',
    japaneseTitle: 'ウィンドウ章 $number',
    publishedAt: DateTime(2026, 8, number),
    blocks: [
      for (var block = 0; block < blockCount; block++)
        AlignedBlock(
          id: 'window-c$number-b$block',
          ordinal: block,
          japanese: List.filled(
            paragraphRepeats,
            '第$number章の本文 $block。'
            '長い文章でスクロール位置を検証します。',
          ).join(),
          translations: {
            for (final source in TranslationSource.values)
              source: List.filled(
                paragraphRepeats,
                '第 $number 章中文正文 $block。'
                '这是用于验证阅读位置的较长段落。',
              ).join(),
          },
        ),
    ],
  );
}

ReaderNovel _windowNovel(List<NovelChapter> chapters) {
  return ReaderNovel(
    id: 'window-novel',
    chineseTitle: '动态窗口测试小说',
    japaneseTitle: '動的ウィンドウテスト',
    author: '测试作者',
    chapters: chapters,
  );
}

ReaderNovel _oversizedBlockNovel({String id = 'oversized-block-novel'}) {
  final chinese = List.filled(120, '这一段文字会跨越多个横向页面，用来验证分页不会退化成垂直滚动。').join();
  final japanese = List.filled(
    120,
    'この段落は複数の横ページにまたがり、縦スクロールへ戻らないことを確認します。',
  ).join();
  return ReaderNovel(
    id: id,
    chineseTitle: '超长段落',
    japaneseTitle: '長い段落',
    author: '测试作者',
    chapters: [
      NovelChapter(
        id: 'oversized-chapter',
        index: 1,
        chineseTitle: '分页测试',
        japaneseTitle: 'ページテスト',
        publishedAt: DateTime(2026, 8, 22),
        blocks: [
          AlignedBlock(
            id: 'oversized-block',
            ordinal: 0,
            japanese: japanese,
            translations: {
              for (final source in TranslationSource.values) source: chinese,
            },
          ),
        ],
      ),
    ],
  );
}

ScrollableState _readerScrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(const ValueKey('reader-stream')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

class _FakeOrientationController implements ReaderOrientationController {
  final applied = <ReaderOrientationPreference>[];
  var resetCount = 0;

  @override
  Future<void> apply(ReaderOrientationPreference preference) async {
    applied.add(preference);
  }

  @override
  Future<void> reset() async {
    resetCount += 1;
  }
}

void main() {
  Future<void> pumpReader(
    WidgetTester tester, {
    ReaderNovel? novel,
    ReadingPosition? initialPosition,
    bool startAtChapterTitle = false,
    ValueChanged<ReadingPosition>? onPositionChanged,
    ValueChanged<ReadingPosition>? onExitPosition,
    ReaderBookmarkChanged? onBookmarkChanged,
    Set<String> initialBookmarkedBlockIds = const {},
    List<ReadingPosition> initialBookmarks = const [],
    ReaderSettings initialSettings = const ReaderSettings(),
    ValueChanged<ReaderSettings>? onSettingsChanged,
    ReaderOrientationController? orientationController,
    Size viewSize = const Size(430, 932),
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        restorationScopeId: 'reader-tests',
        home: ReaderScreen(
          novel: novel ?? fixtureNovel,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          initialPosition: initialPosition,
          startAtChapterTitle: startAtChapterTitle,
          onPositionChanged: onPositionChanged,
          onExitPosition: onExitPosition,
          initialBookmarkedBlockIds: initialBookmarkedBlockIds,
          initialBookmarks: initialBookmarks,
          onBookmarkChanged: onBookmarkChanged,
          initialSettings: initialSettings,
          onSettingsChanged: onSettingsChanged,
          orientationController: orientationController,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpWindowReader(
    WidgetTester tester, {
    required ReaderNovel novel,
    required ReaderChapterDataSource dataSource,
    ReadingPosition? initialPosition,
    ValueChanged<ReadingPosition>? onPositionChanged,
    ValueChanged<ReadingPosition>? onExitPosition,
    ReaderSettings initialSettings = const ReaderSettings(),
  }) async {
    tester.view.physicalSize = const Size(430, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          key: ValueKey('window-reader-${identityHashCode(dataSource)}'),
          novel: novel,
          chapterDataSource: dataSource,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          initialPosition: initialPosition,
          onPositionChanged: onPositionChanged,
          onExitPosition: onExitPosition,
          initialSettings: initialSettings,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> driveReaderToEdge(
    WidgetTester tester, {
    required ReaderLoadDirection direction,
    required bool Function() reached,
  }) async {
    for (var attempt = 0; attempt < 8 && !reached(); attempt++) {
      final position = _readerScrollable(tester).position;
      position.jumpTo(
        direction == ReaderLoadDirection.before
            ? position.minScrollExtent
            : position.maxScrollExtent,
      );
      await tester.pump();
      await tester.pump();
    }
    expect(reached(), isTrue, reason: '阅读器未触发预期的边界请求');
  }

  testWidgets(
    'trimming chapters preserves the exact visible paragraph offset',
    (tester) async {
      final chapters = [for (var n = 1; n <= 9; n++) _windowChapter(n)];
      final block = chapters[5].blocks[3];
      final source = ReaderChapterDataSource(
        catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
        loadAround: (_) => throw StateError('not used'),
        loadAdjacent: (_) => throw StateError('not used'),
      );
      await pumpWindowReader(
        tester,
        novel: _windowNovel(chapters),
        dataSource: source,
        initialPosition: ReadingPosition(
          chapterId: chapters[5].id,
          blockId: block.id,
        ),
      );
      await tester.tapAt(const Offset(215, 350));
      await tester.pump();
      final target = find.byKey(ValueKey('block-${block.id}-chinese'));
      final paragraph = tester.renderObject(target);
      final text = tester.widget(target);
      final top = tester.getTopLeft(target).dy;
      final scroll = _readerScrollable(tester).position;
      scroll.jumpTo(scroll.pixels + 40);
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
        expect(tester.getTopLeft(target).dy, closeTo(top - 40, 1));
        expect(tester.renderObject(target), same(paragraph));
        expect(tester.widget(target), same(text));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scrolling across chapters keeps the reader and hidden chrome', (
    tester,
  ) async {
    final reported = <ReadingPosition>[];
    await pumpReader(
      tester,
      novel: _windowNovel([_windowChapter(1), _windowChapter(2)]),
      onPositionChanged: reported.add,
    );
    await tester.tapAt(const Offset(215, 350));
    await tester.pumpAndSettle();
    final stream = find.byKey(const ValueKey('reader-stream'));
    final chrome = find.byKey(const ValueKey('reader-bottom-chrome'));
    final streamWidget = tester.widget(stream);
    final chromeWidget = tester.widget(chrome);
    final scroll = _readerScrollable(tester).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(reported.last.chapterId, 'window-c2');
    expect(tester.widget(stream), same(streamWidget));
    expect(tester.widget(chrome), same(chromeWidget));
    await tester.tapAt(const Offset(215, 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 2 / 2 章'), findsOneWidget);
  });

  for (final mode in ReaderLayoutMode.values) {
    testWidgets(
      'long $mode reading trims old chapters and still loads backwards',
      (tester) async {
        final chapters = [for (var n = 1; n <= 18; n++) _windowChapter(n)];
        final requests = <ReaderAdjacentRequest>[];
        final positions = <ReadingPosition>[];
        final source = ReaderChapterDataSource(
          catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
          loadAround: (_) => throw StateError('not used'),
          loadAdjacent: (request) async {
            requests.add(request);
            final anchor = chapters.indexWhere(
              (chapter) => chapter.id == request.anchorChapterId,
            );
            final index =
                anchor +
                (request.direction == ReaderLoadDirection.after ? 1 : -1);
            return ReaderChapterWindow(
              chapters: [chapters[index]],
              before: index == 0
                  ? ReaderBoundaryStatus.endOfCatalog
                  : ReaderBoundaryStatus.loadable,
              after: index == chapters.length - 1
                  ? ReaderBoundaryStatus.endOfCatalog
                  : ReaderBoundaryStatus.loadable,
            );
          },
        );
        await pumpWindowReader(
          tester,
          novel: _windowNovel([chapters.first]),
          dataSource: source,
          initialSettings: ReaderSettings(layoutMode: mode),
          onPositionChanged: positions.add,
        );
        await tester.drag(
          find.byKey(const ValueKey('reader-stream')),
          mode == ReaderLayoutMode.scroll
              ? const Offset(0, -200)
              : const Offset(-250, 0),
        );
        await tester.pumpAndSettle();
        for (var n = 1; n < 14; n++) {
          await driveReaderToEdge(
            tester,
            direction: ReaderLoadDirection.after,
            reached: () => requests.any(
              (request) =>
                  request.anchorChapterId == chapters[n - 1].id &&
                  request.direction == ReaderLoadDirection.after,
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(positions, isNotEmpty);
        if (mode == ReaderLayoutMode.scroll) {
          final lists = tester.widgetList<SliverList>(
            find.descendant(
              of: find.byKey(const ValueKey('reader-stream')),
              matching: find.byType(SliverList),
            ),
          );
          expect(
            lists.fold<int>(
              0,
              (sum, list) => sum + list.delegate.estimatedChildCount!,
            ),
            lessThanOrEqualTo(8 * 7 + 2),
          );
        }
        await driveReaderToEdge(
          tester,
          direction: ReaderLoadDirection.before,
          reached: () => requests.any(
            (request) => request.direction == ReaderLoadDirection.before,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('reader keyboard arrows follow the active layout axis', () {
    _expectReaderKeyboardMapping();
  });

  testWidgets('direction keys turn the network reader on its active axis', (
    tester,
  ) async {
    await pumpReader(
      tester,
      novel: _oversizedBlockNovel(id: 'keyboard-vertical-novel'),
      viewSize: const Size(430, 600),
    );
    final vertical = _readerScrollable(tester).position;
    final verticalStart = vertical.pixels;
    expect(vertical.maxScrollExtent, greaterThan(0));
    final verticalKeyboard = tester.widget<KeyboardListener>(
      find.byKey(const ValueKey('reader-keyboard-navigation')),
    );
    expect(verticalKeyboard.focusNode.hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 260));
    expect(vertical.pixels, verticalStart);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(vertical.pixels, greaterThan(verticalStart));

    await pumpReader(
      tester,
      novel: _oversizedBlockNovel(id: 'keyboard-horizontal-novel'),
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
      viewSize: const Size(430, 600),
    );
    final horizontal = _readerScrollable(tester).position;
    final horizontalStart = horizontal.pixels;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 300));
    expect(horizontal.pixels, horizontalStart);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(horizontal.pixels, greaterThan(horizontalStart));
  });

  testWidgets('renders Chinese first with Japanese underneath', (tester) async {
    await pumpReader(tester);

    expect(find.byKey(const ValueKey('reader-restoring')), findsNothing);
    expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byKey(const ValueKey('reader-selection-area')), findsOneWidget);

    final chineseTop = tester
        .getTopLeft(find.byKey(const ValueKey('block-c1-0-chinese')))
        .dy;
    final japaneseTop = tester
        .getTopLeft(find.byKey(const ValueKey('block-c1-0-japanese')))
        .dy;
    expect(chineseTop, lessThan(japaneseTop));
  });

  testWidgets('native selection keeps adaptive actions and blocks page turns', (
    tester,
  ) async {
    await pumpReader(
      tester,
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
    );
    final selection = tester.widget<SelectionArea>(
      find.byKey(const ValueKey('reader-selection-area')),
    );
    expect(selection.selectionControls, isNull);
    expect(selection.contextMenuBuilder, isNotNull);
    expect(find.byType(SelectableText), findsNothing);

    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    selection.onSelectionChanged!(const SelectedContent(plainText: '最后一班列车'));
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    expect(_readerScrollable(tester).position.pixels, 0);

    selection.onSelectionChanged!(null);
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    expect(_readerScrollable(tester).position.pixels, greaterThan(300));
  });

  testWidgets('reader interaction settings disable selection and edge taps', (
    tester,
  ) async {
    await pumpReader(
      tester,
      initialSettings: const ReaderSettings(
        layoutMode: ReaderLayoutMode.pages,
        textSelectionEnabled: false,
        tapPageTurnEnabled: false,
      ),
    );

    expect(find.byKey(const ValueKey('reader-selection-area')), findsNothing);
    final position = _readerScrollable(tester).position;
    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);

    await tester.drag(
      find.byKey(const ValueKey('reader-stream')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(300));
  });

  testWidgets('renders normalized illustration blocks as images, not URLs', (
    tester,
  ) async {
    const imageUrl =
        'https://47209.mitemin.net/userpageimage/viewimagebig/icode/i971569/';
    final novel = ReaderNovel(
      id: 'illustrated-novel',
      chineseTitle: '插图小说',
      japaneseTitle: '挿絵小説',
      author: '作者',
      chapters: [
        NovelChapter(
          id: 'illustrated-chapter',
          index: 1,
          chineseTitle: '第一章',
          japaneseTitle: '第一話',
          publishedAt: DateTime.utc(2026, 8, 18),
          blocks: const [
            AlignedBlock(
              id: 'illustration-1',
              ordinal: 0,
              japanese: '<图片>$imageUrl',
              translations: {},
              kind: AlignedBlockKind.illustration,
            ),
          ],
        ),
      ],
    );

    final pixels = (await tester.runAsync(
      () => createTestImage(width: 40, height: 20, cache: false),
    ))!;
    final cachedProvider = ResizeImage(NetworkImage(imageUrl), width: 398);
    final cacheKey = await cachedProvider.obtainKey(ImageConfiguration.empty);
    final frame = Completer<ImageInfo>();
    final completer = OneFrameImageStreamCompleter(frame.future);
    PaintingBinding.instance.imageCache.putIfAbsent(cacheKey, () => completer);
    frame.complete(ImageInfo(image: pixels.clone()));
    await pumpReader(tester, novel: novel);

    final imageFinder = find.byKey(
      const ValueKey('block-illustration-1-illustration'),
    );
    expect(imageFinder, findsOneWidget);
    expect(find.text('<图片>$imageUrl'), findsNothing);
    final image = tester.widget<Image>(imageFinder);
    final provider = image.image as ResizeImage;
    expect((provider.imageProvider as NetworkImage).url, imageUrl);
    expect(provider.width, 398);
    expect(tester.getSize(imageFinder).aspectRatio, 2);
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pump();
    expect(pixels.debugGetOpenHandleStackTraces(), hasLength(1));
    pixels.dispose();
  });

  testWidgets('captures and restores intra-block reading position', (
    tester,
  ) async {
    final tall = NovelChapter(
      id: 'tall-c1',
      index: 1,
      chineseTitle: '长段落',
      japaneseTitle: '長い段落',
      publishedAt: DateTime(2026, 8, 1),
      blocks: [
        AlignedBlock(
          id: 'tall-b0',
          ordinal: 0,
          japanese: List.filled(40, '長い文章でスクロール位置を検証します。').join('\n'),
          translations: {
            for (final source in TranslationSource.values)
              source: List.filled(40, '这是用于验证阅读位置的较长段落。').join('\n'),
          },
        ),
      ],
    );
    final reported = <ReadingPosition>[];
    await pumpReader(
      tester,
      novel: _windowNovel([tall]),
      onPositionChanged: reported.add,
      onExitPosition: reported.add,
    );
    final scrollable = _readerScrollable(tester);
    expect(scrollable.position.maxScrollExtent, greaterThan(80));
    scrollable.position.jumpTo(
      (scrollable.position.maxScrollExtent * 0.45).clamp(
        48,
        scrollable.position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(reported, isNotEmpty);
    expect(reported.last.blockId, 'tall-b0');
    expect(reported.last.intraBlockOffset, greaterThan(0));

    const restored = ReadingPosition(
      chapterId: 'tall-c1',
      blockId: 'tall-b0',
      intraBlockOffset: 600,
    );
    await pumpReader(
      tester,
      novel: _windowNovel([tall]),
      initialPosition: restored,
    );
    expect(_readerScrollable(tester).position.pixels, greaterThan(40));
  });

  testWidgets('restored deep position stays stable when scrolling both ways', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 36; number++)
        _windowChapter(number, blockCount: 6),
    ];
    final targetChapter = chapters[29];
    final targetBlock = targetChapter.blocks[3];
    await pumpReader(
      tester,
      novel: _windowNovel(chapters),
      initialPosition: ReadingPosition(
        chapterId: targetChapter.id,
        blockId: targetBlock.id,
        intraBlockOffset: 180,
      ),
      viewSize: const Size(430, 720),
    );

    final target = find.byKey(ValueKey('block-${targetBlock.id}-chinese'));
    expect(target, findsOneWidget);
    final beforeTop = tester.getTopLeft(target).dy;
    final scrollable = _readerScrollable(tester).position;
    scrollable.jumpTo(scrollable.pixels + 40);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(target, findsOneWidget);
    expect(tester.getTopLeft(target).dy, closeTo(beforeTop - 40, 2));

    var expectedTop = beforeTop - 40;
    for (final delta in [-80.0, 40.0, 100.0, -100.0]) {
      scrollable.jumpTo(scrollable.pixels + delta);
      expectedTop -= delta;
      await tester.pump();
      expect(target, findsOneWidget);
      expect(tester.getTopLeft(target).dy, closeTo(expectedTop, 2));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(expectedTop, 2));
    }
  });

  testWidgets('finishing a drag publishes the new reading position', (
    tester,
  ) async {
    final reported = <ReadingPosition>[];
    await pumpReader(tester, onPositionChanged: reported.add);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('reader-stream')),
    );
    await tester.dragFrom(
      Offset(viewport.center.dx, viewport.height * .7),
      Offset(0, -viewport.height * .6),
    );
    await tester.pumpAndSettle();

    expect(
      _readerScrollable(tester).position.pixels,
      greaterThan(viewport.height * .4),
    );
    expect(reported, isNotEmpty);
    final saved = reported.last;
    expect(saved.blockId != 'c1-0' || saved.intraBlockOffset > 0, isTrue);
  });

  testWidgets('translation refresh preserves the paragraph being read', (
    tester,
  ) async {
    final translated = _windowChapter(1, blockCount: 12);
    final pending = NovelChapter(
      id: translated.id,
      index: translated.index,
      chineseTitle: translated.chineseTitle,
      japaneseTitle: translated.japaneseTitle,
      publishedAt: translated.publishedAt,
      blocks: translated.blocks,
      translationStates: const {
        TranslationSource.sakura: TranslationState.pending,
      },
    );
    final source = ReaderChapterDataSource(
      catalog: [ReaderChapterCatalogEntry.fromChapter(pending)],
      loadAround: (_) => throw StateError('not used'),
      loadAdjacent: (_) => throw StateError('not used'),
    );
    final block = pending.blocks[3];
    await pumpWindowReader(
      tester,
      novel: _windowNovel([pending]),
      dataSource: source,
      initialPosition: ReadingPosition(
        chapterId: pending.id,
        blockId: block.id,
      ),
    );
    final anchor = find.byKey(ValueKey('block:${block.id}'));
    final top = tester.getTopLeft(anchor).dy;
    source.notifyChapterUpdated(translated);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(anchor).dy, closeTo(top, 2));
    expect(find.byKey(ValueKey('block-${block.id}-chinese')), findsOneWidget);
  });

  testWidgets(
    'paged catalog jump displays a loaded chapter outside the window',
    (tester) async {
      final chapters = [
        for (var number = 1; number <= 36; number++) _windowChapter(number),
      ];
      final target = chapters[29];
      await pumpReader(
        tester,
        novel: _windowNovel(chapters),
        initialSettings: const ReaderSettings(
          layoutMode: ReaderLayoutMode.pages,
        ),
        viewSize: const Size(430, 720),
      );
      await tester.tap(find.byKey(const ValueKey('catalog-button')));
      await tester.pumpAndSettle();
      final tile = find.byKey(ValueKey('catalog-chapter-${target.id}'));
      await tester.scrollUntilVisible(
        tile,
        320,
        continuous: true,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('chapter-catalog-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('chapter-boundary-${target.id}')),
        findsOneWidget,
      );
      final previousPageTap =
          tester
              .getRect(find.byKey(const ValueKey('reader-stream')))
              .centerLeft +
          const Offset(20, 0);
      await tester.tapAt(previousPageTap);
      await tester.pumpAndSettle();
      await tester.tapAt(previousPageTap);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 29 章中文正文'), findsWidgets);
    },
  );

  testWidgets('chapter refresh during navigation keeps the selected chapter', (
    tester,
  ) async {
    final chapters = [_windowChapter(1), _windowChapter(2)];
    final reported = <ReadingPosition>[];
    final source = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => throw StateError('not used'),
      loadAdjacent: (_) => throw StateError('not used'),
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel(chapters),
      dataSource: source,
      onPositionChanged: reported.add,
    );
    await tester.tap(find.byKey(const ValueKey('next-chapter-button')));
    await tester.pump();
    source.notifyChapterUpdated(_windowChapter(2, paragraphRepeats: 8));
    await tester.pumpAndSettle();

    final target = find.byKey(const ValueKey('block:window-c2-b0'));
    expect(target, findsOneWidget);
    expect(
      tester
          .getRect(target)
          .overlaps(
            tester.getRect(find.byKey(const ValueKey('reader-stream'))),
          ),
      isTrue,
    );
    expect(find.text('第 2 / 2 章 · 本章 0%'), findsOneWidget);
    expect(reported.last.chapterId, 'window-c2');
  });

  testWidgets('a delayed edge turn cannot move a newly selected chapter', (
    tester,
  ) async {
    final chapters = [for (var n = 1; n <= 4; n++) _windowChapter(n)];
    final response = Completer<ReaderChapterWindow>();
    var requested = false;
    final source = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => throw StateError('not used'),
      loadAdjacent: (_) {
        requested = true;
        return response.future;
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel(chapters.sublist(2)),
      dataSource: source,
    );
    expect(requested, isFalse);
    expect(_readerScrollable(tester).position.extentBefore, closeTo(0, 1));
    final readingArea = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '滚动阅读区域',
      ),
    );
    readingArea.properties.onDecrease!();
    await tester.pump();
    expect(requested, isTrue);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-chapter-scrubber')),
    );
    slider.onChangeEnd!(3);
    await tester.pumpAndSettle();
    final scrollPosition = _readerScrollable(tester).position;
    final beforeTurn = scrollPosition.pixels;
    readingArea.properties.onIncrease!();
    await tester.pumpAndSettle();
    expect(scrollPosition.pixels, greaterThan(beforeTurn));
    final afterTurn = scrollPosition.pixels;

    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[1]],
        before: ReaderBoundaryStatus.loadable,
        after: ReaderBoundaryStatus.loadable,
      ),
    );
    await tester.pumpAndSettle();
    expect(scrollPosition.pixels, closeTo(afterTurn, 1));
  });

  testWidgets('catalog jump in a long loaded novel lands deterministically', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 36; number++)
        _windowChapter(
          number,
          blockCount: number == 8 ? 2 : 6,
          paragraphRepeats: number == 8 ? 200 : 4,
        ),
    ];
    final initialChapter = chapters[29];
    final targetChapter = chapters[8];
    await pumpReader(
      tester,
      novel: _windowNovel(chapters),
      initialPosition: ReadingPosition(
        chapterId: initialChapter.id,
        blockId: initialChapter.blocks[3].id,
      ),
      viewSize: const Size(430, 720),
    );

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    final targetTile = find.byKey(
      ValueKey('catalog-chapter-${targetChapter.id}'),
    );
    await tester.scrollUntilVisible(
      targetTile,
      320,
      continuous: true,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('chapter-catalog-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(targetTile.hitTestable(), findsOneWidget);
    await tester.tap(targetTile);
    await tester.pumpAndSettle();

    final chapterTitle = find.byKey(
      ValueKey('chapter-boundary-${targetChapter.id}'),
    );
    expect(chapterTitle, findsOneWidget);
    final beforeTop = tester.getTopLeft(chapterTitle).dy;
    expect(beforeTop, inInclusiveRange(70, 150));
    expect(
      find.byKey(ValueKey('block-${targetChapter.blocks.first.id}-chinese')),
      findsOneWidget,
    );

    final gesture = await tester.startGesture(const Offset(215, 400));
    // The first move wins the drag gesture; subsequent moves scroll content.
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    var expectedTop = tester.getTopLeft(chapterTitle).dy;
    expect(expectedTop, lessThan(beforeTop));
    // Reverse while the finger is still down: loading earlier paragraphs
    // must neither move the text independently nor cancel the drag.
    for (final delta in [40.0, -80.0, 80.0, 160.0, -160.0]) {
      await gesture.moveBy(Offset(0, delta));
      expectedTop += delta;
      await tester.pump();
      expect(chapterTitle, findsOneWidget);
      expect(tester.getTopLeft(chapterTitle).dy, closeTo(expectedTop, 2));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('an unread chapter opens on its title before the first block', (
    tester,
  ) async {
    const firstBlock = ReadingPosition(chapterId: 'chapter-1', blockId: 'c1-0');
    await pumpReader(
      tester,
      initialPosition: firstBlock,
      startAtChapterTitle: true,
    );

    final chapterTitle = find.byKey(
      const ValueKey('chapter-boundary-chapter-1'),
    );
    final firstBody = find.byKey(const ValueKey('block-c1-0-chinese'));
    expect(chapterTitle, findsOneWidget);
    expect(firstBody, findsOneWidget);
    expect(tester.getRect(chapterTitle).top, inInclusiveRange(60, 180));
    expect(
      tester.getRect(firstBody).top,
      greaterThan(tester.getRect(chapterTitle).bottom),
    );
  });

  testWidgets('reading taps dismiss chrome and center taps reveal it', (
    tester,
  ) async {
    await pumpReader(tester);
    final body = tester.widget(
      find.byKey(const ValueKey('block-c1-0-chinese')),
    );

    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('reader-bottom-chrome')),
    );

    expect(chrome().opacity, 1);
    await tester.tapAt(const Offset(20, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);
    expect(
      tester.widget(find.byKey(const ValueKey('block-c1-0-chinese'))),
      same(body),
    );

    await tester.tapAt(const Offset(20, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);

    await tester.tapAt(const Offset(215, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 1);
  });

  testWidgets('paged mode scrolls horizontally and snaps taps and drags', (
    tester,
  ) async {
    await pumpReader(
      tester,
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
    );
    final position = _readerScrollable(tester).position;
    final pageView = tester.widget<PageView>(
      find.byKey(const ValueKey('reader-horizontal-pages')),
    );
    expect(pageView.scrollDirection, Axis.horizontal);
    expect(pageView.physics, isA<PageScrollPhysics>());
    expect(position.axis, Axis.horizontal);
    expect(position.maxScrollExtent, greaterThan(300));

    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(position.pixels, 0);

    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    final afterTap = position.pixels;
    expect(afterTap, closeTo(430, 1));

    await tester.drag(
      find.byKey(const ValueKey('reader-stream')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(0, 1));

    await tester.drag(
      find.byKey(const ValueKey('reader-stream')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(afterTap, 1));
  });

  testWidgets(
    'paged mode uses the full page instead of reserving chrome space',
    (tester) async {
      await pumpReader(
        tester,
        initialSettings: const ReaderSettings(
          layoutMode: ReaderLayoutMode.pages,
        ),
      );

      final firstChinese = find.byKey(const ValueKey('block-c1-0-chinese'));
      final firstJapanese = find.byKey(const ValueKey('block-c1-0-japanese'));
      expect(firstChinese, findsOneWidget);
      expect(firstJapanese, findsOneWidget);
      expect(tester.getRect(firstChinese).left, lessThan(430));
      expect(tester.getRect(firstJapanese).bottom, greaterThan(466));
    },
  );

  testWidgets('paged mode fragments oversized blocks without vertical scroll', (
    tester,
  ) async {
    await pumpReader(
      tester,
      novel: _oversizedBlockNovel(),
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
    );

    final reader = find.byKey(const ValueKey('reader-stream'));
    final position = _readerScrollable(tester).position;
    expect(
      find.descendant(of: reader, matching: find.byType(SingleChildScrollView)),
      findsNothing,
    );
    expect(position.axis, Axis.horizontal);
    expect(
      position.maxScrollExtent,
      greaterThan(position.viewportDimension * 3),
    );
    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('block-oversized-block-chinese-fragment-0')),
      findsWidgets,
    );
    final horizontalOffset = position.pixels;
    await tester.drag(reader, const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(position.pixels, closeTo(horizontalOffset, 1));
  });

  testWidgets('paged mode reuses measured fragments for bookmark changes', (
    tester,
  ) async {
    await pumpReader(
      tester,
      novel: _oversizedBlockNovel(),
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
    );
    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    final before = tester.widget<ReaderHorizontalBlockFragmentView>(
      find.byType(ReaderHorizontalBlockFragmentView).first,
    );
    await tester.tapAt(const Offset(215, 466));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookmark-button')));
    await tester.pumpAndSettle();
    final after = tester.widget<ReaderHorizontalBlockFragmentView>(
      find.byType(ReaderHorizontalBlockFragmentView).first,
    );
    expect(after.bookmarked, isTrue);
    expect(after.fragment, same(before.fragment));
    tester.view.physicalSize = const Size(500, 932);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ReaderHorizontalBlockFragmentView>(
            find.byType(ReaderHorizontalBlockFragmentView).first,
          )
          .fragment,
      isNot(same(after.fragment)),
    );
  });

  testWidgets(
    'paged mode preserves its semantic anchor after viewport resize',
    (tester) async {
      final bookmarkChanges = <(ReadingPosition, bool)>[];
      await pumpReader(
        tester,
        novel: _windowNovel([_windowChapter(1, blockCount: 12)]),
        initialSettings: const ReaderSettings(
          layoutMode: ReaderLayoutMode.pages,
        ),
        onBookmarkChanged: (position, bookmarked) {
          bookmarkChanges.add((position, bookmarked));
        },
      );

      await tester.tapAt(const Offset(410, 466));
      await tester.pump(const Duration(milliseconds: 220));
      for (var page = 0; page < 4; page++) {
        await tester.tapAt(const Offset(410, 466));
        await tester.pumpAndSettle();
      }
      InkWell bookmarkAction() => tester.widget<InkWell>(
        find
            .descendant(
              of: find.byKey(const ValueKey('bookmark-button')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      bookmarkAction().onTap!();
      await tester.pumpAndSettle();
      final beforeResize = bookmarkChanges.single.$1;

      tester.view.physicalSize = const Size(932, 430);
      await tester.pump();
      await tester.pumpAndSettle();
      bookmarkAction().onTap!();
      await tester.pumpAndSettle();
      final afterResize = bookmarkChanges.last.$1;

      expect(afterResize.chapterId, beforeResize.chapterId);
      expect(afterResize.blockId, beforeResize.blockId);
    },
  );

  testWidgets(
    'scroll mode preserves its semantic anchor across desktop and fold widths',
    (tester) async {
      final bookmarkChanges = <(ReadingPosition, bool)>[];
      final chapter = _windowChapter(1, blockCount: 24);
      final targetBlock = chapter.blocks[12];
      await pumpReader(
        tester,
        novel: _windowNovel([chapter]),
        initialPosition: ReadingPosition(
          chapterId: chapter.id,
          blockId: targetBlock.id,
          intraBlockOffset: 250,
        ),
        onBookmarkChanged: (position, bookmarked) {
          bookmarkChanges.add((position, bookmarked));
        },
        viewSize: const Size(430, 800),
      );

      InkWell bookmarkAction() => tester.widget<InkWell>(
        find
            .descendant(
              of: find.byKey(const ValueKey('bookmark-button')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      bookmarkAction().onTap!();
      await tester.pump();

      tester.view.physicalSize = const Size(1200, 760);
      await tester.pump();
      await tester.pumpAndSettle();
      bookmarkAction().onTap!();
      await tester.pump();

      tester.view.physicalSize = const Size(673, 840);
      await tester.pump();
      await tester.pumpAndSettle();
      bookmarkAction().onTap!();
      await tester.pump();

      expect(bookmarkChanges, hasLength(3));
      expect(bookmarkChanges.map((change) => change.$1.chapterId).toSet(), {
        chapter.id,
      });
      expect(bookmarkChanges.map((change) => change.$1.blockId).toSet(), {
        targetBlock.id,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scroll mode supports free vertical drag and overlapping taps', (
    tester,
  ) async {
    await pumpReader(tester);
    final position = _readerScrollable(tester).position;
    expect(position.axis, Axis.vertical);
    final beforeTap = position.pixels;

    await tester.tapAt(const Offset(410, 466));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(const Offset(410, 466));
    await tester.pumpAndSettle();
    final afterTap = position.pixels;
    expect(afterTap - beforeTap, closeTo(position.viewportDimension - 72, 1));

    await tester.tapAt(const Offset(20, 466));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(beforeTap, 1));

    await tester.drag(
      find.byKey(const ValueKey('reader-stream')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(beforeTap));
  });

  testWidgets('layout setting persists through the reader callback', (
    tester,
  ) async {
    final changes = <ReaderSettings>[];
    await pumpReader(tester, onSettingsChanged: changes.add);

    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻页'));
    await tester.tap(find.byKey(const ValueKey('settings-apply')));
    await tester.pumpAndSettle();

    expect(changes.single.layoutMode, ReaderLayoutMode.pages);
    expect(
      find.byKey(const ValueKey('reader-horizontal-pages')),
      findsOneWidget,
    );
    expect(_readerScrollable(tester).position.axis, Axis.horizontal);
  });

  testWidgets('interaction switches persist through the reader callback', (
    tester,
  ) async {
    final changes = <ReaderSettings>[];
    await pumpReader(tester, onSettingsChanged: changes.add);

    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-text-selection')));
    await tester.tap(find.byKey(const ValueKey('settings-tap-page-turn')));
    await tester.tap(find.byKey(const ValueKey('settings-apply')));
    await tester.pumpAndSettle();

    expect(changes.single.textSelectionEnabled, isFalse);
    expect(changes.single.tapPageTurnEnabled, isFalse);
    expect(find.byKey(const ValueKey('reader-selection-area')), findsNothing);
  });

  testWidgets('reader chrome reports semantic progress and changes chapters', (
    tester,
  ) async {
    await pumpReader(tester);

    expect(find.text('第 1 / 4 章 · 本章 0%'), findsOneWidget);
    final previous = tester.widget<IconButton>(
      find.byKey(const ValueKey('previous-chapter-button')),
    );
    expect(previous.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('next-chapter-button')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 4 章 · 本章 0%'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c2-0-chinese')), findsOneWidget);
  });

  testWidgets('chapter scrubber previews and opens its target', (tester) async {
    await pumpReader(tester);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-chapter-scrubber')),
    );

    slider.onChanged!(3);
    await tester.pump();
    expect(find.text('第 4 / 4 章 · 星港'), findsOneWidget);
    slider.onChangeEnd!(3);
    await tester.pumpAndSettle();

    expect(find.text('第 4 / 4 章 · 本章 0%'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c4-0-chinese')), findsOneWidget);
    final next = tester.widget<IconButton>(
      find.byKey(const ValueKey('next-chapter-button')),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('appearance sheet previews, cancels, and commits palettes', (
    tester,
  ) async {
    final changes = <ReaderSettings>[];
    await pumpReader(tester, onSettingsChanged: changes.add);
    Scaffold scaffold() => tester.widget<Scaffold>(find.byType(Scaffold));

    expect(scaffold().backgroundColor, const Color(0xFFF5F2E8));
    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-palette-sepia')));
    await tester.pumpAndSettle();
    expect(scaffold().backgroundColor, const Color(0xFFF0E1C2));

    await tester.tap(find.byKey(const ValueKey('settings-cancel')));
    await tester.pumpAndSettle();
    expect(scaffold().backgroundColor, const Color(0xFFF5F2E8));
    expect(changes, isEmpty);

    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-palette-sepia')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-apply')));
    await tester.pumpAndSettle();

    expect(changes.single.palette, ReaderPalette.sepia);
    expect(scaffold().backgroundColor, const Color(0xFFF0E1C2));
  });

  testWidgets('typography and responsive bilingual columns render directly', (
    tester,
  ) async {
    await pumpReader(
      tester,
      viewSize: const Size(1200, 900),
      initialSettings: const ReaderSettings(
        fontFamily: ReaderFontFamily.systemSerif,
        bodyBold: true,
        pageMargin: 40,
        paragraphSpacing: 24,
        readingWidth: 1000,
        columnLayout: ReaderColumnLayout.twoColumns,
      ),
    );

    final chinese = tester.widget<Text>(
      find.byKey(const ValueKey('block-c1-0-chinese')),
    );
    expect(chinese.style!.fontFamily, 'serif');
    expect(chinese.style!.fontWeight, FontWeight.w600);
    expect(
      find.byKey(const ValueKey('block-c1-0-parallel-columns')),
      findsOneWidget,
    );
    final padding = tester.widget<Padding>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('block-c1-0-parallel-columns')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect((padding.padding as EdgeInsets).left, 40);
    expect((padding.padding as EdgeInsets).bottom, 24);
  });

  testWidgets('phones remain single-column when two columns are requested', (
    tester,
  ) async {
    await pumpReader(
      tester,
      initialSettings: const ReaderSettings(
        columnLayout: ReaderColumnLayout.twoColumns,
      ),
    );

    expect(
      find.byKey(const ValueKey('block-c1-0-parallel-columns')),
      findsNothing,
    );
    final chineseBottom = tester
        .getBottomLeft(find.byKey(const ValueKey('block-c1-0-chinese')))
        .dy;
    final japaneseTop = tester
        .getTopLeft(find.byKey(const ValueKey('block-c1-0-japanese')))
        .dy;
    expect(chineseBottom, lessThan(japaneseTop));
  });

  testWidgets('reader applies and resets its orientation preference', (
    tester,
  ) async {
    final orientation = _FakeOrientationController();
    await pumpReader(
      tester,
      orientationController: orientation,
      initialSettings: const ReaderSettings(
        orientationPreference: ReaderOrientationPreference.landscape,
      ),
    );

    expect(orientation.applied, [ReaderOrientationPreference.landscape]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(orientation.resetCount, 1);
  });

  testWidgets('scrolling and inactivity dismiss reader chrome', (tester) async {
    await pumpReader(tester);

    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('reader-bottom-chrome')),
    );

    expect(chrome().opacity, 1);
    await tester.drag(
      find.byKey(const ValueKey('reader-stream')),
      const Offset(0, -160),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);

    await tester.tapAt(const Offset(215, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 1);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);
  });

  testWidgets('mode control hides Japanese without moving Chinese', (
    tester,
  ) async {
    await pumpReader(tester);

    await tester.tap(find.byKey(const ValueKey('reading-mode-button')));
    await tester.pumpAndSettle();

    expect(find.text('中文'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsNothing);
  });

  testWidgets('catalog jumps to pending chapter and preserves original', (
    tester,
  ) async {
    await pumpReader(tester);

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-chapter-chapter-3')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('translation-state-chapter-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('block-c3-0-chinese')), findsNothing);
    expect(find.byKey(const ValueKey('block-c3-0-japanese')), findsOneWidget);
  });

  testWidgets('pending translation refresh replaces the on-screen chapter', (
    tester,
  ) async {
    const chapterId = 'pending-c1';
    final pending = NovelChapter(
      id: chapterId,
      index: 1,
      chineseTitle: '待译章节',
      japaneseTitle: '未訳の章',
      publishedAt: DateTime(2026, 8, 1),
      translationStates: const {
        TranslationSource.sakura: TranslationState.pending,
      },
      blocks: const [
        AlignedBlock(
          id: 'pending-c1-b0',
          ordinal: 0,
          japanese: '本文',
          translations: {},
        ),
      ],
    );
    final complete = NovelChapter(
      id: chapterId,
      index: 1,
      chineseTitle: '待译章节',
      japaneseTitle: '未訳の章',
      publishedAt: DateTime(2026, 8, 1),
      translationStates: const {
        TranslationSource.sakura: TranslationState.complete,
      },
      blocks: const [
        AlignedBlock(
          id: 'pending-c1-b0',
          ordinal: 0,
          japanese: '本文',
          translations: {TranslationSource.sakura: '正文'},
        ),
      ],
    );
    final dataSource = ReaderChapterDataSource(
      catalog: [ReaderChapterCatalogEntry.fromChapter(pending)],
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (_) => Future.value(
        const ReaderChapterWindow(
          chapters: [],
          before: ReaderBoundaryStatus.endOfCatalog,
          after: ReaderBoundaryStatus.endOfCatalog,
        ),
      ),
    );

    await pumpWindowReader(
      tester,
      novel: ReaderNovel(
        id: 'pending-novel',
        chineseTitle: '待译小说',
        japaneseTitle: '未訳',
        author: '作者',
        chapters: [pending],
      ),
      dataSource: dataSource,
    );

    expect(
      find.byKey(const ValueKey('block-pending-c1-b0-chinese')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('translation-state-pending-c1')),
      findsOneWidget,
    );

    dataSource.notifyChapterUpdated(complete);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('block-pending-c1-b0-chinese')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('translation-state-pending-c1')),
      findsNothing,
    );
  });

  testWidgets('reader catalog groups chapters by section title', (
    tester,
  ) async {
    final chapters = [_windowChapter(1), _windowChapter(2)];
    final dataSource = ReaderChapterDataSource(
      catalog: [
        ReaderChapterCatalogEntry.fromChapter(chapters[0], sectionTitle: '上卷'),
        ReaderChapterCatalogEntry.fromChapter(chapters[1], sectionTitle: '下卷'),
      ],
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (_) => Future.value(
        const ReaderChapterWindow(
          chapters: [],
          before: ReaderBoundaryStatus.endOfCatalog,
          after: ReaderBoundaryStatus.endOfCatalog,
        ),
      ),
    );

    await pumpWindowReader(
      tester,
      novel: _windowNovel(chapters),
      dataSource: dataSource,
    );
    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();

    expect(find.text('上卷'), findsOneWidget);
    expect(find.text('下卷'), findsOneWidget);
    expect(
      find.byKey(ValueKey('catalog-chapter-${chapters[0].id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('catalog-chapter-${chapters[1].id}')),
      findsOneWidget,
    );
  });

  testWidgets('switching to an available source restores Chinese', (
    tester,
  ) async {
    await pumpReader(tester);

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-chapter-chapter-3')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('translation-source-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-gpt')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('translation-state-chapter-3')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('block-c3-0-chinese')), findsOneWidget);
  });

  testWidgets('restores the semantic chapter anchor after restart', (
    tester,
  ) async {
    await pumpReader(tester);

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-chapter-chapter-3')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('translation-state-chapter-3')),
      findsOneWidget,
    );

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-restoring')), findsNothing);
    final restoredBlock = find.byKey(const ValueKey('block-c3-0-japanese'));
    expect(restoredBlock, findsOneWidget);
    expect(find.byKey(const ValueKey('block-c3-0-chinese')), findsNothing);
    expect(tester.getTopLeft(restoredBlock).dy, inInclusiveRange(0, 932));
  });

  testWidgets(
    'restoration and a late native resize do not report synthetic progress',
    (tester) async {
      final reported = <ReadingPosition>[];
      await pumpReader(
        tester,
        initialPosition: const ReadingPosition(
          chapterId: 'chapter-3',
          blockId: 'c3-0',
        ),
        onPositionChanged: reported.add,
      );

      expect(find.byKey(const ValueKey('block-c3-0-japanese')), findsOneWidget);
      expect(reported, isEmpty);

      tester.view.physicalSize = const Size(1200, 760);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('block-c3-0-japanese')), findsOneWidget);
      expect(reported, isEmpty);
    },
  );

  testWidgets('removed saved block returns to its chapter top', (tester) async {
    await pumpReader(
      tester,
      initialPosition: const ReadingPosition(
        chapterId: 'chapter-2',
        blockId: 'removed-by-revision',
      ),
    );

    final chapterTop = find.byKey(const ValueKey('chapter-boundary-chapter-2'));
    expect(chapterTop, findsOneWidget);
    expect(tester.getTopLeft(chapterTop).dy, inInclusiveRange(0, 932));
  });

  testWidgets('ordinary reader exit saves the visible semantic anchor', (
    tester,
  ) async {
    final reported = <ReadingPosition>[];
    await pumpReader(tester, onPositionChanged: reported.add);
    expect(reported, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(reported, isNotEmpty);
    expect(reported.last.chapterId, 'chapter-1');
    expect(reported.last.blockId, 'c1-0');
  });

  testWidgets('bookmark changes expose semantic positions for persistence', (
    tester,
  ) async {
    final changes = <(ReadingPosition, bool)>[];
    await pumpReader(
      tester,
      onBookmarkChanged: (position, bookmarked) {
        changes.add((position, bookmarked));
      },
    );

    await tester.tap(find.byKey(const ValueKey('bookmark-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookmark-button')));
    await tester.pumpAndSettle();

    expect(changes.map((change) => change.$2), [true, false]);
    expect(changes.first.$1.chapterId, 'chapter-1');
    expect(changes.first.$1.blockId, 'c1-0');
  });

  testWidgets('bookmarks show markers and navigate inside the reader', (
    tester,
  ) async {
    await pumpReader(
      tester,
      initialBookmarks: const [
        ReadingPosition(chapterId: 'chapter-1', blockId: 'c1-0'),
        ReadingPosition(chapterId: 'chapter-2', blockId: 'c2-1'),
      ],
    );

    expect(
      find.byKey(const ValueKey('block-c1-0-bookmark-marker')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-navigation-bookmarks')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-bookmarks-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-bookmark-c2-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-bookmark-c2-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('block-c2-1-chinese')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('block-c2-1-bookmark-marker')),
      findsOneWidget,
    );
    expect(find.textContaining('第 2 / 4 章'), findsOneWidget);
  });

  testWidgets('bookmark list removes a saved position in place', (
    tester,
  ) async {
    final changes = <(ReadingPosition, bool)>[];
    await pumpReader(
      tester,
      initialBookmarks: const [
        ReadingPosition(chapterId: 'chapter-1', blockId: 'c1-0'),
      ],
      onBookmarkChanged: (position, bookmarked) {
        changes.add((position, bookmarked));
      },
    );

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-navigation-bookmarks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-reader-bookmark-c1-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-bookmarks-empty')),
      findsOneWidget,
    );
    expect(changes.single.$1.blockId, 'c1-0');
    expect(changes.single.$2, isFalse);
  });

  testWidgets('reader settings can initialize from and write to local state', (
    tester,
  ) async {
    final changes = <ReaderSettings>[];
    await pumpReader(
      tester,
      initialSettings: const ReaderSettings(
        readingMode: ReadingMode.chineseOnly,
      ),
      onSettingsChanged: changes.add,
    );

    expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reading-mode-button')));
    await tester.pumpAndSettle();

    expect(changes.single.readingMode, ReadingMode.chineseJapanese);
  });

  testWidgets('forward boundary appends once without moving the viewport', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++) _windowChapter(number),
    ];
    final requests = <ReaderAdjacentRequest>[];
    final response = Completer<ReaderChapterWindow>();
    final reported = <ReadingPosition>[];
    final dataSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (request) {
        requests.add(request);
        if (request.direction == ReaderLoadDirection.after) {
          return response.future;
        }
        return Future.value(
          const ReaderChapterWindow(
            chapters: [],
            before: ReaderBoundaryStatus.unavailable,
            after: ReaderBoundaryStatus.loadable,
          ),
        );
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[2], chapters[3]]),
      dataSource: dataSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks.first.id,
      ),
      onPositionChanged: reported.add,
      onExitPosition: (_) {},
    );

    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.after,
      reached: () => requests.isNotEmpty,
    );
    expect(requests, hasLength(1));
    expect(requests.single.anchorChapterId, chapters[3].id);
    expect(requests.single.direction, ReaderLoadDirection.after);
    expect(
      find.byKey(const ValueKey('reader-load-after-loading')),
      findsOneWidget,
    );

    for (var repeat = 0; repeat < 3; repeat++) {
      final position = _readerScrollable(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    expect(requests, hasLength(1));
    final beforePixels = _readerScrollable(tester).position.pixels;
    final progressBeforeCompletion = reported.length;
    final retainedText = find.byKey(
      ValueKey('block-${chapters[3].blocks.last.id}-chinese'),
    );
    final retainedWidget = tester.widget(retainedText);
    final retainedParagraph = tester.renderObject(retainedText);

    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[3], chapters[4]],
        before: ReaderBoundaryStatus.loadable,
        after: ReaderBoundaryStatus.unavailable,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      _readerScrollable(tester).position.pixels,
      closeTo(beforePixels, 0.5),
    );
    expect(reported, hasLength(progressBeforeCompletion));
    expect(tester.widget(retainedText), same(retainedWidget));
    expect(tester.renderObject(retainedText), same(retainedParagraph));
    final position = _readerScrollable(tester).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('block-${chapters[4].blocks.last.id}-japanese')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-boundary-after-unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('prepend preserves the exact anchor without synthetic progress', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++)
        _windowChapter(number, blockCount: number == 2 ? 160 : 6),
    ];
    final requests = <ReaderAdjacentRequest>[];
    final response = Completer<ReaderChapterWindow>();
    final reported = <ReadingPosition>[];
    final dataSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (request) {
        requests.add(request);
        if (request.direction == ReaderLoadDirection.before) {
          return response.future;
        }
        return Future.value(
          const ReaderChapterWindow(
            chapters: [],
            before: ReaderBoundaryStatus.loadable,
            after: ReaderBoundaryStatus.unavailable,
          ),
        );
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[2], chapters[3]]),
      dataSource: dataSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks.first.id,
      ),
      onPositionChanged: reported.add,
      onExitPosition: (_) {},
    );

    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.before,
      reached: () => requests.isNotEmpty,
    );
    expect(requests, hasLength(1));
    expect(requests.single.anchorChapterId, chapters[2].id);
    // Keep reading while the request is in flight; preserve the position at
    // completion, including when only part of a long previous chapter fits.
    await tester.dragFrom(const Offset(215, 480), const Offset(0, -100));
    await tester.pump();
    final anchor = find.byKey(
      ValueKey('block-${chapters[2].blocks.first.id}-chinese'),
    );
    expect(anchor, findsOneWidget);
    final anchorTop = tester.getTopLeft(anchor).dy;
    final progressBeforeCompletion = reported.length;

    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[1], chapters[2]],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.loadable,
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(anchor).dy, closeTo(anchorTop, 1.0));
    expect(reported, hasLength(progressBeforeCompletion));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(anchorTop, 1.0));
    expect(reported, hasLength(progressBeforeCompletion));
    for (var attempt = 0; attempt < 4; attempt++) {
      final position = _readerScrollable(tester).position;
      position.jumpTo(position.minScrollExtent);
      await tester.pumpAndSettle();
      if (find
          .byKey(ValueKey('chapter-boundary-${chapters[1].id}'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(ValueKey('chapter-boundary-${chapters[1].id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-boundary-before-unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('paged prepend preserves the current block and keeps turning', (
    tester,
  ) async {
    final chapters = [for (var n = 1; n <= 4; n++) _windowChapter(n)];
    final response = Completer<ReaderChapterWindow>();
    final reported = <ReadingPosition>[];
    var requested = false;
    final source = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => throw StateError('not used'),
      loadAdjacent: (_) {
        requested = true;
        return response.future;
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel(chapters.sublist(2)),
      dataSource: source,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks[3].id,
      ),
      initialSettings: const ReaderSettings(layoutMode: ReaderLayoutMode.pages),
      onPositionChanged: reported.add,
    );
    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.before,
      reached: () => requested,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final anchor = reported.last;
    final count = reported.length;

    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[1]],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.endOfCatalog,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('block:${anchor.blockId}')), findsOneWidget);
    expect(reported, hasLength(count));
    final position = _readerScrollable(tester).position;
    final restoredPage = position.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      position.pixels,
      closeTo(restoredPage - position.viewportDimension, 1),
    );
  });

  testWidgets('full catalog lazily replaces and jumps to an unloaded window', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++) _windowChapter(number),
    ];
    final aroundRequests = <String>[];
    final response = Completer<ReaderChapterWindow>();
    final reported = <ReadingPosition>[];
    final dataSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (chapterId) {
        aroundRequests.add(chapterId);
        return response.future;
      },
      loadAdjacent: (_) => Future.value(
        const ReaderChapterWindow(
          chapters: [],
          before: ReaderBoundaryStatus.unavailable,
          after: ReaderBoundaryStatus.unavailable,
        ),
      ),
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[2], chapters[3]]),
      dataSource: dataSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks.first.id,
      ),
      onPositionChanged: reported.add,
      onExitPosition: (_) {},
    );

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('catalog-chapter-${chapters.last.id}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('catalog-chapter-${chapters[3].id}')));
    await tester.pumpAndSettle();
    expect(aroundRequests, isEmpty);

    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    final progressBeforeLazyJump = reported.length;
    await tester.tap(
      find.byKey(ValueKey('catalog-chapter-${chapters.last.id}')),
    );
    await tester.pump();
    expect(aroundRequests, [chapters.last.id]);
    expect(
      find.byKey(ValueKey('reader-catalog-loading-${chapters.last.id}')),
      findsOneWidget,
    );

    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[4], chapters[5]],
        before: ReaderBoundaryStatus.loadable,
        after: ReaderBoundaryStatus.endOfCatalog,
      ),
    );
    await tester.pumpAndSettle();

    expect(reported, hasLength(progressBeforeLazyJump + 1));
    expect(reported.last.chapterId, chapters.last.id);
    expect(reported.last.blockId, chapters.last.blocks.first.id);
    expect(
      find.byKey(ValueKey('block-${chapters.last.blocks.first.id}-chinese')),
      findsOneWidget,
    );
    final catalogPosition = _readerScrollable(tester).position;
    catalogPosition.jumpTo(catalogPosition.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-boundary-after-endOfCatalog')),
      findsOneWidget,
    );
  });

  testWidgets('failed adjacent load retries once and deduplicates taps', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++) _windowChapter(number),
    ];
    final retryResponse = Completer<ReaderChapterWindow>();
    final requests = <ReaderAdjacentRequest>[];
    final dataSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (request) {
        requests.add(request);
        if (requests.length == 1) {
          return Future.error(StateError('temporary failure'));
        }
        return retryResponse.future;
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[2], chapters[3]]),
      dataSource: dataSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks.first.id,
      ),
      onExitPosition: (_) {},
    );

    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.after,
      reached: () => requests.isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-load-after-error')),
      findsOneWidget,
    );
    final position = _readerScrollable(tester).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));

    final retry = find.byKey(const ValueKey('retry-reader-load-after'));
    await tester.tap(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(requests, hasLength(2));
    expect(
      find.byKey(const ValueKey('reader-load-after-loading')),
      findsOneWidget,
    );

    retryResponse.complete(
      ReaderChapterWindow(
        chapters: [chapters[3], chapters[4]],
        before: ReaderBoundaryStatus.loadable,
        after: ReaderBoundaryStatus.unavailable,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-load-after-error')), findsNothing);
  });

  testWidgets('true latest and offline boundaries do not retry forever', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++) _windowChapter(number),
    ];
    var latestCalls = 0;
    final latestSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (_) {
        latestCalls += 1;
        return Future.error(StateError('must not load past latest'));
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters.last]),
      dataSource: latestSource,
      initialPosition: ReadingPosition(
        chapterId: chapters.last.id,
        blockId: chapters.last.blocks.first.id,
      ),
      onExitPosition: (_) {},
    );
    final latestPosition = _readerScrollable(tester).position;
    latestPosition.jumpTo(latestPosition.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(latestCalls, 0);
    expect(
      find.byKey(const ValueKey('reader-boundary-after-endOfCatalog')),
      findsOneWidget,
    );

    var offlineCalls = 0;
    final offlineSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (request) {
        offlineCalls += 1;
        return Future.value(
          const ReaderChapterWindow(
            chapters: [],
            before: ReaderBoundaryStatus.loadable,
            after: ReaderBoundaryStatus.unavailable,
          ),
        );
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[3]]),
      dataSource: offlineSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[3].id,
        blockId: chapters[3].blocks.first.id,
      ),
      onExitPosition: (_) {},
    );
    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.after,
      reached: () => offlineCalls == 1,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-boundary-after-unavailable')),
      findsOneWidget,
    );
    for (var repeat = 0; repeat < 3; repeat++) {
      final offlinePosition = _readerScrollable(tester).position;
      offlinePosition.jumpTo(offlinePosition.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(offlineCalls, 1);
    expect(find.byKey(const ValueKey('reader-load-after-error')), findsNothing);
  });

  testWidgets('late adjacent completion after dispose is ignored', (
    tester,
  ) async {
    final chapters = [
      for (var number = 1; number <= 6; number++) _windowChapter(number),
    ];
    final response = Completer<ReaderChapterWindow>();
    var requests = 0;
    final progress = <ReadingPosition>[];
    final exits = <ReadingPosition>[];
    final dataSource = ReaderChapterDataSource(
      catalog: chapters.map(ReaderChapterCatalogEntry.fromChapter).toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (_) {
        requests += 1;
        return response.future;
      },
    );
    await pumpWindowReader(
      tester,
      novel: _windowNovel([chapters[2], chapters[3]]),
      dataSource: dataSource,
      initialPosition: ReadingPosition(
        chapterId: chapters[2].id,
        blockId: chapters[2].blocks.first.id,
      ),
      onPositionChanged: progress.add,
      onExitPosition: exits.add,
    );
    await driveReaderToEdge(
      tester,
      direction: ReaderLoadDirection.after,
      reached: () => requests == 1,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    final progressAfterDispose = progress.length;
    final exitsAfterDispose = exits.length;
    response.complete(
      ReaderChapterWindow(
        chapters: [chapters[3], chapters[4]],
        before: ReaderBoundaryStatus.loadable,
        after: ReaderBoundaryStatus.loadable,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(progress, hasLength(progressAfterDispose));
    expect(exits, hasLength(exitsAfterDispose));
  });
}
