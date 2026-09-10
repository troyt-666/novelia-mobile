import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';
import 'package:jfzreader/main.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';

import 'support/fixture_content_coordinator.dart';

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
    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: FixtureContentCoordinator(fixtureCatalogNovels),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'theme rebuild reuses the shelf and reading completion refreshes it',
    (tester) async {
      final repository = SqliteOfflineRepository.openInMemory();
      await pumpApp(tester, repository);
      NoveliaShell shell() =>
          tester.widget<NoveliaShell>(find.byType(NoveliaShell));
      final before = shell().continuedReads;
      final originalShell = shell();
      await originalShell.catalogController!.refreshCatalog();
      await tester.pumpAndSettle();
      expect(shell(), same(originalShell));
      expect(shell().continuedReads, same(before));
      shell().onThemeModeChanged(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(shell().continuedReads, same(before));

      repository.saveReadingProgress(
        LocalReadingProgress(
          novelId: fixtureNovel.id,
          position: const ReadingPosition(
            chapterId: 'chapter-2',
            blockId: 'c2-0',
          ),
          updatedAt: DateTime.utc(2026, 9, 6),
        ),
      );
      shell().onReaderClosed?.call();
      await tester.pumpAndSettle();
      expect(shell().continuedReads.single.position.chapterId, 'chapter-2');
      expect(shell().continuedReads, isNot(same(before)));
    },
  );

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

    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: FixtureContentCoordinator(fixtureCatalogNovels),
      ),
    );

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
    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();

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

  testWidgets('settings manages offline downloads and clears only cache', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    final payload = CachedChapterPayload(
      id: 'settings-cache-payload',
      novelId: fixtureNovel.id,
      chapterId: 'chapter-1',
      index: 1,
      chineseTitle: '',
      japaneseTitle: '',
      previousChapterId: null,
      nextChapterId: null,
      publishedAt: null,
      japaneseBlocks: const ['原文'],
      translations: {
        TranslationSource.sakura: CachedChapterTranslation(
          availability: TranslationAvailability.complete,
          blocks: ['译文'],
        ),
      },
      fetchedAt: DateTime.utc(2026, 8, 18),
      revision: 'r1',
    );
    repository.cacheChapterPayload(
      payload: payload,
      copy: OfflineChapterCopy(
        id: 'settings-cache-copy',
        novelId: fixtureNovel.id,
        chapterId: 'chapter-1',
        kind: OfflineCopyKind.cacheCopy,
        translationSource: TranslationSource.sakura,
        originalBytes: 120,
        translationBytes: 80,
        storedAt: DateTime.utc(2026, 8, 18),
        payloadId: payload.id,
        revision: 'r1',
      ),
    );
    await pumpApp(tester, repository);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();

    final offlineStorage = find.byKey(
      const ValueKey('settings-offline-storage'),
    );
    await tester.scrollUntilVisible(
      offlineStorage,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(offlineStorage);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('downloads-management-screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('downloads-management-empty')),
      findsOneWidget,
    );
    Navigator.of(
      tester.element(find.byKey(const ValueKey('downloads-management-screen'))),
    ).pop();
    await tester.pumpAndSettle();

    expect(find.textContaining('200 B · 1 章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-cache-storage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clear-reading-cache-button')));
    await tester.pumpAndSettle();

    expect(repository.listCopies(kind: OfflineCopyKind.cacheCopy), isEmpty);
    expect(find.text('0 B · 0 章 · 上限 256 MB'), findsOneWidget);
  });

  testWidgets('bookmark action commits to SQLite', (tester) async {
    final repository = SqliteOfflineRepository.openInMemory();
    await pumpApp(tester, repository);

    await tester.tap(
      find
          .byKey(ValueKey('open-details-${fixtureCatalogNovels.first.id}'))
          .first,
    );
    await tester.pumpAndSettle();
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
