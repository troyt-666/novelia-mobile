import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/features/reader/reader_screen.dart';
import 'package:novelia_reader/fixtures/reader_fixture.dart';

NovelChapter _windowChapter(int number, {int blockCount = 6}) {
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
            4,
            '第$number章の本文 $block。'
            '長い文章でスクロール位置を検証します。',
          ).join(),
          translations: {
            for (final source in TranslationSource.values)
              source: List.filled(
                4,
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

void main() {
  Future<void> pumpReader(
    WidgetTester tester, {
    ReadingPosition? initialPosition,
    ValueChanged<ReadingPosition>? onPositionChanged,
    ReaderBookmarkChanged? onBookmarkChanged,
    Set<String> initialBookmarkedBlockIds = const {},
    ReaderSettings initialSettings = const ReaderSettings(),
    ValueChanged<ReaderSettings>? onSettingsChanged,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        restorationScopeId: 'reader-tests',
        home: ReaderScreen(
          novel: fixtureNovel,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          initialPosition: initialPosition,
          onPositionChanged: onPositionChanged,
          initialBookmarkedBlockIds: initialBookmarkedBlockIds,
          onBookmarkChanged: onBookmarkChanged,
          initialSettings: initialSettings,
          onSettingsChanged: onSettingsChanged,
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

  testWidgets('renders Chinese first with Japanese underneath', (tester) async {
    await pumpReader(tester);

    expect(find.byKey(const ValueKey('reader-restoring')), findsNothing);
    expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsOneWidget);

    final chineseTop = tester
        .getTopLeft(find.byKey(const ValueKey('block-c1-0-chinese')))
        .dy;
    final japaneseTop = tester
        .getTopLeft(find.byKey(const ValueKey('block-c1-0-japanese')))
        .dy;
    expect(chineseTop, lessThan(japaneseTop));
  });

  testWidgets('only a center tap toggles reader chrome', (tester) async {
    await pumpReader(tester);

    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('reader-bottom-chrome')),
    );

    expect(chrome().opacity, 1);
    await tester.tapAt(const Offset(215, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);

    await tester.tapAt(const Offset(20, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 0);

    await tester.tapAt(const Offset(215, 466));
    await tester.pump(const Duration(milliseconds: 220));
    expect(chrome().opacity, 1);
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

  testWidgets('restoration never reports its internal jump as user progress', (
    tester,
  ) async {
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
  });

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
