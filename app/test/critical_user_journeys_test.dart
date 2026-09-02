import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/core/account/account_session_controller.dart';
import 'package:jfzreader/core/account/account_sync_models.dart';
import 'package:jfzreader/core/account/secure_session_store.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';
import 'package:jfzreader/gateway/novelia/novelia_account_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_auth_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/main.dart';

import 'support/fixture_content_coordinator.dart';

void main() => runCriticalUserJourneys();

void runCriticalUserJourneys({bool useDeviceViewport = false}) {
  testWidgets('login unlocks account-only library data', (tester) async {
    final repository = SqliteOfflineRepository.openInMemory();
    final store = InMemoryAccountSessionStore();
    final accountGateway = _AccountJourneyGateway();
    final sessionController = AccountSessionController(
      gateway: _AuthJourneyGateway(),
      store: store,
    );

    await _pumpApp(
      tester,
      repository,
      useDeviceViewport: useDeviceViewport,
      accountSessionController: sessionController,
      accountGateway: accountGateway,
    );

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.text('远程收藏夹暂不可用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-account')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('account-username-field')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-password-field')),
      'fixture-password',
    );
    await tester.tap(find.byKey(const ValueKey('account-login-button')));
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('已登录 · member'), findsOneWidget);
    expect(store.value, isNotNull);
    expect(store.value!.encode(), isNot(contains('fixture-password')));

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('favorite-folder-fixture-folder')),
      findsOneWidget,
    );
    expect(find.text('我的收藏'), findsOneWidget);
  });

  testWidgets('reader discovers and searches the catalog', (tester) async {
    final repository = SqliteOfflineRepository.openInMemory();
    await _pumpApp(tester, repository, useDeviceViewport: useDeviceViewport);

    expect(find.text('最多点击'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);
    await _openDetails(tester, fixtureCatalogNovels.first);
    expect(
      find.byKey(ValueKey('novel-details-${fixtureNovel.id}')),
      findsOneWidget,
    );
    await _closeDetails(tester, fixtureCatalogNovels.first);

    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('discover-search-field'));
    await tester.scrollUntilVisible(
      search,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(search, '齿轮图书馆');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('已加载 1 部小说'), findsOneWidget);
    final result = fixtureCatalogNovels[1];
    await _openDetails(tester, result);
    expect(find.text(result.chineseTitle), findsWidgets);
    expect(repository.recentSearches(), ['齿轮图书馆']);
  });

  testWidgets(
    'reader scrolls, turns pages, jumps chapters, and resumes progress',
    (tester) async {
      final repository = SqliteOfflineRepository.openInMemory();
      await _pumpApp(tester, repository, useDeviceViewport: useDeviceViewport);
      await _openDetails(tester, fixtureCatalogNovels.first);
      await tester.tap(find.byKey(const ValueKey('start-reading-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);
      expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-stream')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final beforeScroll = scrollable.position.pixels;
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(scrollable.position.minScrollExtent),
      );
      final scrollGesture =
          beforeScroll < scrollable.position.maxScrollExtent - 1
          ? const Offset(0, -360)
          : const Offset(0, 360);
      final readerRect = tester.getRect(
        find.byKey(const ValueKey('reader-stream')),
      );
      await tester.dragFrom(
        Offset(readerRect.left + 8, readerRect.center.dy),
        scrollGesture,
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, isNot(closeTo(beforeScroll, 1)));
      final afterScroll = repository.readingProgressFor(fixtureNovel.id);
      expect(afterScroll, isNotNull);

      await _closeReader(tester);
      await _closeDetails(tester, fixtureCatalogNovels.first);
      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
      final continued = find.byKey(
        ValueKey('continued-read-${fixtureNovel.id}'),
      );
      expect(continued, findsOneWidget);
      await tester.tap(continued);
      await tester.pumpAndSettle();
      final restoredBlock = find.byKey(
        ValueKey('block-${afterScroll!.position.blockId}-chinese'),
      );
      expect(restoredBlock, findsOneWidget);
      expect(
        tester
            .getRect(restoredBlock)
            .overlaps(
              Offset.zero &
                  tester.view.physicalSize / tester.view.devicePixelRatio,
            ),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('catalog-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-chapter-chapter-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-c2-0-chinese')), findsOneWidget);
      expect(find.byKey(const ValueKey('block-c2-0-japanese')), findsOneWidget);
      expect(
        repository.readingProgressFor(fixtureNovel.id)!.position.chapterId,
        'chapter-2',
      );

      await _closeReader(tester);
      expect(continued, findsOneWidget);
      await tester.tap(continued);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-c2-0-chinese')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('previous-chapter-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('翻页'));
      await tester.tap(find.byKey(const ValueKey('reader-palette-sepia')));
      await tester.tap(find.byKey(const ValueKey('settings-apply')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reader-horizontal-pages')),
        findsOneWidget,
      );
      expect(
        repository.appSettings()!.readerSettings.layoutMode,
        ReaderLayoutMode.pages,
      );
      expect(
        repository.appSettings()!.readerSettings.palette,
        ReaderPalette.sepia,
      );

      final pageScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-stream')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final beforePage = pageScrollable.position.pixels;
      final swipe = beforePage < pageScrollable.position.maxScrollExtent
          ? const Offset(-300, 0)
          : const Offset(300, 0);
      final pageRect = tester.getRect(
        find.byKey(const ValueKey('reader-stream')),
      );
      await tester.dragFrom(
        Offset(
          swipe.dx.isNegative ? pageRect.right - 8 : pageRect.left + 8,
          pageRect.center.dy,
        ),
        swipe,
      );
      await tester.pumpAndSettle();
      expect(pageScrollable.position.pixels, isNot(closeTo(beforePage, 1)));

      await _closeReader(tester);
      expect(continued, findsOneWidget);
    },
  );

  testWidgets('offline download survives cache clearing and app recreation', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    final downloadCoordinator = _FixtureDownloadCoordinator(repository);
    final cachedPayload = CachedChapterPayload(
      id: 'journey-cache-payload',
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
          blocks: const ['译文'],
        ),
      },
      fetchedAt: DateTime.utc(2026, 8, 18),
      revision: 'fixture-cache-v1',
    );
    repository.cacheChapterPayload(
      payload: cachedPayload,
      copy: OfflineChapterCopy(
        id: 'journey-cache-copy',
        novelId: fixtureNovel.id,
        chapterId: 'chapter-1',
        kind: OfflineCopyKind.cacheCopy,
        translationSource: TranslationSource.sakura,
        originalBytes: 120,
        translationBytes: 80,
        storedAt: DateTime.utc(2026, 8, 18),
        payloadId: cachedPayload.id,
        revision: 'fixture-cache-v1',
      ),
    );
    await _pumpApp(
      tester,
      repository,
      useDeviceViewport: useDeviceViewport,
      downloadCoordinator: downloadCoordinator,
    );

    await _openDetails(tester, fixtureCatalogNovels.first);
    await tester.tap(find.byKey(const ValueKey('download-novel-button')));
    await tester.pumpAndSettle();
    expect(find.text('已加入离线下载'), findsOneWidget);
    expect(
      repository.listCopies(kind: OfflineCopyKind.offlineDownload),
      hasLength(fixtureNovel.chapters.length),
    );

    await _closeDetails(tester, fixtureCatalogNovels.first);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    final cache = find.byKey(const ValueKey('settings-cache-storage'));
    await tester.scrollUntilVisible(
      cache,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(cache);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clear-reading-cache-button')));
    await tester.pumpAndSettle();

    expect(find.text('已清除 1 章阅读缓存'), findsOneWidget);
    expect(repository.listCopies(kind: OfflineCopyKind.cacheCopy), isEmpty);
    expect(
      repository.listCopies(kind: OfflineCopyKind.offlineDownload),
      hasLength(fixtureNovel.chapters.length),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: FixtureContentCoordinator(fixtureCatalogNovels),
        downloadCoordinator: downloadCoordinator,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();

    final download = find.byKey(
      ValueKey('offline-download-${fixtureNovel.id}'),
    );
    expect(download, findsOneWidget);
    await tester.tap(download);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-reading-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('block-c1-0-chinese')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-c1-0-japanese')), findsOneWidget);
  });
}

Future<void> _pumpApp(
  WidgetTester tester,
  SqliteOfflineRepository repository, {
  required bool useDeviceViewport,
  AccountSessionController? accountSessionController,
  NoveliaAccountGateway? accountGateway,
  NoveliaDownloadCoordinator? downloadCoordinator,
}) async {
  if (!useDeviceViewport) {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    repository.close();
  });
  await tester.pumpWidget(
    NoveliaReaderApp(
      repository: repository,
      contentCoordinator: FixtureContentCoordinator(fixtureCatalogNovels),
      accountSessionController: accountSessionController,
      accountGateway: accountGateway,
      downloadCoordinator: downloadCoordinator,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester, CatalogNovel novel) async {
  await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
  await tester.pumpAndSettle();
}

Future<void> _closeDetails(WidgetTester tester, CatalogNovel novel) async {
  Navigator.of(
    tester.element(find.byKey(ValueKey('novel-details-${novel.id}'))),
  ).pop();
  await tester.pumpAndSettle();
}

Future<void> _closeReader(WidgetTester tester) async {
  Navigator.of(
    tester.element(find.byKey(const ValueKey('reader-stream'))),
  ).pop();
  await tester.pumpAndSettle();
}

class _AuthJourneyGateway implements NoveliaAuthGateway {
  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) async => _session(username);

  @override
  Future<void> logout(StoredAccountSession session) async {}

  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) async =>
      session;
}

class _AccountJourneyGateway implements NoveliaAccountGateway {
  @override
  Future<List<RemoteFavoriteFolder>> listFavoriteFolders() async => const [
    RemoteFavoriteFolder(id: 'fixture-folder', title: '我的收藏'),
  ];

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listFavoriteWebNovels({
    required String folderId,
    int page = 0,
    int pageSize = 30,
  }) async => const NoveliaPage(items: [], pageCount: 0);

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listReadHistory({
    int page = 0,
    int pageSize = 30,
  }) async => const NoveliaPage(items: [], pageCount: 0);

  @override
  Future<RemoteFavoriteFolder> createFavoriteFolder(String title) async =>
      RemoteFavoriteFolder(id: title, title: title);

  @override
  Future<void> favoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {}

  @override
  Future<void> unfavoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {}

  @override
  Future<void> updateReadHistory({
    required String providerId,
    required String novelId,
    required String chapterId,
  }) async {}
}

class _FixtureDownloadCoordinator implements NoveliaDownloadCoordinator {
  _FixtureDownloadCoordinator(this.repository);

  final SqliteOfflineRepository repository;

  @override
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId) async {
    final intent = repository.intentById(intentId);
    if (intent is! NovelDownloadIntent) {
      throw StateError('Unknown fixture download intent $intentId.');
    }
    final now = DateTime.utc(2026, 8, 18);
    final created = repository.reconcileIntent(
      intentId: intentId,
      knownChapterIds: fixtureNovel.chapters.map((chapter) => chapter.id),
      now: now,
    );
    for (final initialTask in created) {
      final chapter = fixtureNovel.chapters.firstWhere(
        (chapter) => chapter.id == initialTask.chapterId,
      );
      final originalBytes = chapter.blocks.fold<int>(
        0,
        (total, block) => total + utf8.encode(block.japanese).length,
      );
      final translationBytes =
          chapter.translationState(intent.translationSource) ==
              TranslationState.complete
          ? chapter.blocks.fold<int>(
              0,
              (total, block) =>
                  total +
                  utf8
                      .encode(
                        block.translations[intent.translationSource] ?? '',
                      )
                      .length,
            )
          : null;
      final totalBytes = originalBytes + (translationBytes ?? 0);
      var task = initialTask.beginFetching(now, expectedBytes: totalBytes);
      repository.saveTask(task);
      task = task.reportFetchProgress(now, bytesReceived: totalBytes);
      repository.saveTask(task);
      task = task.beginValidation(now);
      repository.saveTask(task);
      task = task.beginStoring(now);
      repository.saveTask(task);
      repository.commitStoredTask(
        taskId: task.id,
        copy: OfflineChapterCopy(
          id: 'copy::${task.id}',
          novelId: task.novelId,
          chapterId: task.chapterId,
          kind: OfflineCopyKind.offlineDownload,
          translationSource: task.translationSource,
          originalBytes: originalBytes,
          translationBytes: translationBytes,
          storedAt: now,
          intentId: task.intentId,
          revision: 'fixture-v1',
        ),
        now: now,
      );
    }
    final tasks = repository.listTasks(intentId: intentId);
    return NoveliaDownloadRun(
      intentId: intentId,
      availability: CatalogAvailability.available,
      usedCachedToc: false,
      knownChapterCount: fixtureNovel.chapters.length,
      createdTaskCount: created.length,
      refreshedCopyCount: 0,
      refreshFailureCount: 0,
      tasks: tasks,
    );
  }
}

StoredAccountSession _session(String username) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token =
      '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({'sub': username, 'role': 'member', 'iat': 1788192000, 'crat': 1788105600, 'exp': 4102444800})}.signature';
  return StoredAccountSession(
    cookieHeader: 'refresh-token=fixture',
    accessToken: token,
  );
}
