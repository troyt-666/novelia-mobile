import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/database/local_state_repository.dart';
import 'package:novelia_reader/core/database/sqlite_offline_repository.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/core/offline/offline_models.dart';
import 'package:novelia_reader/fixtures/catalog_fixture.dart';
import 'package:novelia_reader/fixtures/reader_fixture.dart';
import 'package:novelia_reader/main.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    SqliteOfflineRepository repository,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(repository.close);
    await tester.pumpWidget(NoveliaReaderApp(repository: repository));
    await tester.pumpAndSettle();
  }

  testWidgets('restores persisted app settings and top-level destination', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    final now = DateTime.utc(2026, 8, 17);
    repository.saveAppSettings(
      LocalAppSettings(
        readerSettings: const ReaderSettings(
          readingMode: ReadingMode.chineseOnly,
          translationSource: TranslationSource.gpt,
        ),
        themePreference: ThemePreference.dark,
        notifyNewChapters: false,
        cacheLimitBytes: 64 * 1024 * 1024,
        updatedAt: now,
      ),
    );
    repository.saveLastRoute(
      LastRouteState(routeName: '/settings', updatedAt: now),
    );

    await pumpApp(tester, repository);

    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('reopens an interrupted reader at the semantic anchor', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    final now = DateTime.utc(2026, 8, 17);
    const position = ReadingPosition(chapterId: 'chapter-3', blockId: 'c3-0');
    repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: fixtureNovel.id,
        position: position,
        updatedAt: now,
      ),
    );
    repository.saveLastRoute(
      LastRouteState(
        routeName: '/reader',
        novelId: fixtureNovel.id,
        position: position,
        updatedAt: now,
      ),
    );

    await pumpApp(tester, repository);

    expect(find.byKey(const ValueKey('block-c3-0-japanese')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c3-0-chinese')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reader-back-button')));
    await tester.pumpAndSettle();
    expect(repository.lastRoute()!.routeName, '/discover');
    expect(
      repository.readingProgressFor(fixtureNovel.id)!.position.chapterId,
      'chapter-3',
    );
  });

  testWidgets('reader restoration never paints Discover before the anchor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 8, 17);
    const position = ReadingPosition(chapterId: 'chapter-3', blockId: 'c3-0');
    repository.saveLastRoute(
      LastRouteState(
        routeName: '/reader',
        novelId: fixtureNovel.id,
        position: position,
        updatedAt: now,
      ),
    );

    await tester.pumpWidget(NoveliaReaderApp(repository: repository));

    expect(find.text('发现'), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-restore-placeholder')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('block-c3-0-japanese')), findsOneWidget);
  });

  testWidgets('recent searches survive recreation and clear durably', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    repository.saveRecentSearches(['齿轮图书馆', '雪春']);
    await pumpApp(tester, repository);

    final search = find.byKey(const ValueKey('discover-search-field'));
    await tester.scrollUntilVisible(
      search,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('recent-search-齿轮图书馆')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clear-search-history-button')));
    await tester.pumpAndSettle();
    expect(repository.recentSearches(), isEmpty);
  });

  testWidgets('bookmark and Novel Download actions commit to SQLite', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    await pumpApp(tester, repository);

    await tester.tap(
      find
          .byKey(ValueKey('open-details-${fixtureCatalogNovels.first.id}'))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-novel-button')));
    await tester.pumpAndSettle();

    expect(repository.listIntents(), hasLength(1));
    expect(repository.listTasks(), hasLength(fixtureNovel.chapters.length));
    expect(
      repository.listTasks().every(
        (task) => task.state == DownloadTaskState.stored,
      ),
      isTrue,
    );
    expect(
      repository.listCopies(kind: OfflineCopyKind.offlineDownload),
      hasLength(fixtureNovel.chapters.length),
    );
    expect(
      repository
          .listCopies(kind: OfflineCopyKind.offlineDownload)
          .firstWhere((copy) => copy.chapterId == 'chapter-3')
          .hasTranslation,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('start-reading-button')));
    await tester.pumpAndSettle();
    expect(repository.lastRoute()!.routeName, '/reader');
    expect(repository.lastRoute()!.position!.chapterId, 'chapter-1');
    expect(repository.lastRoute()!.position!.blockId, 'c1-0');
    await tester.tap(find.byKey(const ValueKey('bookmark-button')));
    await tester.pumpAndSettle();

    expect(repository.listBookmarks(novelId: fixtureNovel.id), hasLength(1));
  });
}
