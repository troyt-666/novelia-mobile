import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/shell/library_screen.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';

import 'support/library_fixture.dart';

void main() {
  testWidgets('continue reading remains actionable to a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = LibraryFixture(1);
    var resumed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryScreen(
            onOpenNovel: (_) {},
            onOpenPosition: (_, _) => resumed = true,
            continuedReads: fixture.reads,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^继续阅读：')));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    expect(resumed, isTrue);
    semantics.dispose();
  });

  Future<void> pumpShelf(
    WidgetTester tester,
    LibraryFixture fixture, {
    double scale = 1,
    Size size = const Size(360, 720),
    ValueChanged<LibraryProtectedDownload>? onDownload,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff397b62)),
        ),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: LibraryScreen(
              onOpenNovel: (_) {},
              onOpenDownload: onDownload,
              continuedReads: fixture.reads,
              protectedDownloads: fixture.downloads,
              onDownloadsManageRequested: () {},
              onReadingHistoryRequested: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('library-tab-$name')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    '100 books build lazily and keep independent searches sorts and scroll',
    (tester) async {
      final fixture = LibraryFixture(100);
      await pumpShelf(tester, fixture);
      final continueList = find.byKey(
        const PageStorageKey('library-continue-scroll'),
      );
      final continueController = tester
          .widget<CustomScrollView>(continueList)
          .controller!;
      expect(
        find.byKey(const ValueKey('continued-read-shelf-fixture-99')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('library-continue-search')),
        '星港',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-continue-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-sort-title')));
      await tester.pumpAndSettle();
      await tester.drag(continueList, const Offset(0, -700));
      await tester.pumpAndSettle();
      final continueOffset = continueController.offset;
      expect(continueOffset, greaterThan(0));
      expect(
        find.byKey(const ValueKey('library-tab-downloads')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-bookmarks-button')).hitTestable(),
        findsOneWidget,
      );
      await tab(tester, 'downloads');
      await tester.enterText(
        find.byKey(const ValueKey('library-downloads-search')),
        '雨声',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-filter-incomplete')));
      await tester.pumpAndSettle();
      final downloadList = find.byKey(
        const PageStorageKey('library-downloads-scroll'),
      );
      final downloadController = tester
          .widget<CustomScrollView>(downloadList)
          .controller!;
      await tester.drag(downloadList, const Offset(0, -650));
      await tester.pumpAndSettle();
      final downloadOffset = downloadController.offset;
      await tab(tester, 'continue');
      expect(continueController.offset, closeTo(continueOffset, 1));
      continueController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('library-continue-search')),
            )
            .controller!
            .text,
        '星港',
      );
      expect(find.text('书名排序'), findsOneWidget);
      await tab(tester, 'downloads');
      expect(downloadController.offset, closeTo(downloadOffset, 1));
      downloadController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('library-downloads-search')),
            )
            .controller!
            .text,
        '雨声',
      );
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('library-filter-incomplete')),
            )
            .selected,
        isTrue,
      );
      expect(find.text('最近活动'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download filters distinguish failures pauses and multiple sources',
    (tester) async {
      final fixture = LibraryFixture(5);
      final opened = <LibraryProtectedDownload>[];
      await pumpShelf(tester, fixture, onDownload: opened.add);
      await tab(tester, 'downloads');
      await tester.tap(find.byKey(const ValueKey('library-filter-complete')));
      await tester.pumpAndSettle();
      expect(find.text('2 项下载'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('offline-download-shelf-fixture-0::gpt')),
      );
      expect(
        opened.single.translationSource,
        fixture.downloads.last.translationSource,
      );
      final failed = find.byKey(const ValueKey('library-filter-failed'));
      await tester.ensureVisible(failed);
      await tester.tap(failed);
      await tester.pumpAndSettle();
      expect(find.text('1 项下载'), findsOneWidget);
      expect(find.textContaining('下载失败'), findsOneWidget);
      final paused = find.byKey(const ValueKey('library-filter-paused'));
      await tester.ensureVisible(paused);
      await tester.tap(paused);
      await tester.pumpAndSettle();
      expect(find.text('1 项下载'), findsOneWidget);
      expect(find.textContaining('已暂停'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(720, 360),
    const Size(1000, 800),
  ]) {
    testWidgets('long titles and 200% text reflow at $size', (tester) async {
      await pumpShelf(tester, LibraryFixture(5), size: size, scale: 2);
      await tab(tester, 'downloads');
      await tester.drag(
        find.byKey(const PageStorageKey('library-downloads-scroll')),
        const Offset(0, -550),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-tab-continue')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tab(tester, 'favorites');
      expect(find.text('远程收藏夹暂不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
