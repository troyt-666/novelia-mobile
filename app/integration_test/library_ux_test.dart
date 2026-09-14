import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/reader/reader_screen.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_catalog_controller.dart';
import 'package:jfzreader/gateway/novelia/novelia_reader_window.dart';

import '../test/support/fixture_content_coordinator.dart';
import '../test/support/library_fixture.dart';

/// Native UI evidence only. All catalog, progress and downloads are invented;
/// this entry point opens no persistent repository and no network gateway.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bookshelf native fixture review', (tester) async {
    await binding.convertFlutterSurfaceToImage();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot(name);
    }

    for (final count in [0, 5, 100]) {
      await tester.pumpWidget(_shelf(count, key: ValueKey('count-$count')));
      await capture('library-$count-continue');
      await tester.tap(find.byKey(const ValueKey('library-tab-downloads')));
      await capture('library-$count-downloads');
      if (count == 100) {
        await tester.drag(
          find.byKey(const PageStorageKey('library-downloads-scroll')),
          const Offset(0, -900),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library-tab-continue')).hitTestable(),
          findsOneWidget,
        );
        await capture('library-100-scrolled');
        await tester.tap(
          find.byKey(const ValueKey('library-bookmarks-button')),
        );
        await capture('library-bookmarks');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-tab-favorites')));
        await capture('library-favorites');
      }
    }
    await tester.pumpWidget(_shelf(5, dark: true, key: const ValueKey('dark')));
    await capture('library-dark-continue');
    await tester.tap(find.byKey(const ValueKey('library-tab-downloads')));
    await capture('library-dark-downloads');
    await tester.pumpWidget(_shelf(5, scale: 2, key: const ValueKey('large')));
    await capture('library-large-text-continue');
    await tester.tap(find.byKey(const ValueKey('library-tab-downloads')));
    await capture('library-large-text-downloads');
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
    ]);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-downloads-search')),
      findsOneWidget,
    );
    await capture('library-landscape-large-text');
    await SystemChrome.setPreferredOrientations([]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

Widget _shelf(
  int count, {
  bool dark = false,
  double scale = 1,
  required Key key,
}) => _FixtureShell(key: key, count: count, dark: dark, scale: scale);

class _FixtureShell extends StatefulWidget {
  const _FixtureShell({
    required this.count,
    required this.dark,
    required this.scale,
    super.key,
  });
  final int count;
  final bool dark;
  final double scale;

  @override
  State<_FixtureShell> createState() => _FixtureShellState();
}

class _FixtureShellState extends State<_FixtureShell> {
  late final fixture = LibraryFixture(widget.count);
  late final coordinator = FixtureContentCoordinator(fixture.novels);
  late final feeds = NoveliaCatalogController(
    contentCoordinator: coordinator,
    canAccessRestrictedContent: () => false,
  );

  @override
  void dispose() {
    feeds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: widget.dark
            ? const Color(0xff78b99a)
            : const Color(0xff397b62),
        brightness: widget.dark ? Brightness.dark : Brightness.light,
      ),
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans CJK SC',
        'Hiragino Sans',
      ],
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(widget.scale)),
      child: child!,
    ),
    home: NoveliaShell(
      initialDestination: 2,
      catalogController: feeds,
      continuedReads: fixture.reads,
      protectedDownloads: fixture.downloads,
      bookmarks: [
        for (final item in fixture.reads.take(5))
          LibraryBookmarkItem(
            id: item.novel.id,
            novel: item.novel,
            position: item.position,
            chapterLabel: item.chapterLabel,
          ),
      ],
      remoteFavorites: countIsEmpty
          ? const RemoteFavoritesViewModel.empty()
          : RemoteFavoritesViewModel.available(const [
              LibraryFavoriteFolder(id: 'later', title: '稍后阅读', novelCount: 12),
              LibraryFavoriteFolder(id: 'loved', title: '喜欢的故事', novelCount: 8),
            ]),
      readingHistoryLoader: (_) async =>
          throw StateError('Fixture history is unavailable'),
      onDownloadManagementRequested: (_, item) async => item,
      readerLaunchLoader: NoveliaReaderWindowFactory(
        contentCoordinator: coordinator,
      ).loaderFor(TranslationSource.sakura),
      downloadReaderLaunchLoader: (download) =>
          NoveliaReaderWindowFactory(contentCoordinator: coordinator).create(
            novel: download.novel,
            selectedChapter: null,
            requestedPosition: null,
            translationSource: download.translationSource,
          ),
      readerBuilder: (_, data) => ReaderScreen(
        novel: data.novel,
        initialPosition: data.initialPosition,
        themeMode: ThemeMode.system,
        onThemeModeChanged: (_) {},
      ),
      themeMode: widget.dark ? ThemeMode.dark : ThemeMode.light,
      onThemeModeChanged: (_) {},
    ),
  );

  bool get countIsEmpty => widget.count == 0;
}
