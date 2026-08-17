import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/model/reader_models.dart';
import 'package:novelia_reader/features/discover/catalog_models.dart';
import 'package:novelia_reader/features/discover/discover_screen.dart';
import 'package:novelia_reader/features/novel_details/novel_details_screen.dart';
import 'package:novelia_reader/features/shell/novelia_shell.dart';
import 'package:novelia_reader/fixtures/catalog_fixture.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    CatalogAvailability availability = CatalogAvailability.available,
    ReaderPageBuilder? readerBuilder,
    List<CatalogNovel>? novels,
    NovelDetailsLoader? novelDetailsLoader,
    ReaderLaunchLoader? readerLaunchLoader,
    NovelCommentPageLoader? commentPageLoader,
    ReaderRouteOpened? onReaderOpened,
    NovelDownloadRequested? onDownloadRequested,
    CatalogCriteriaRequested? onCatalogCriteriaRequested,
    ValueChanged<CatalogNovel>? onFavoriteRequested,
    ValueChanged<CatalogNovel>? onOpenOriginalRequested,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: NoveliaShell(
          novels: novels ?? fixtureCatalogNovels,
          catalogAvailability: availability,
          novelDetailsLoader: novelDetailsLoader,
          readerLaunchLoader: readerLaunchLoader,
          commentPageLoader: commentPageLoader,
          onReaderOpened: onReaderOpened,
          onDownloadRequested: onDownloadRequested,
          onCatalogCriteriaRequested: onCatalogCriteriaRequested,
          onFavoriteRequested: onFavoriteRequested,
          onOpenOriginalRequested: onOpenOriginalRequested,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          readerBuilder:
              readerBuilder ??
              (_, data) => Scaffold(
                body: Text(
                  '${data.novel.chineseTitle}:${data.initialPosition?.chapterId ?? 'start'}',
                  key: const ValueKey('fixture-reader-route'),
                ),
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('exposes Discover, Library, and Settings destinations', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.text('发现'), findsWidgets);
    expect(find.text('继续阅读'), findsNothing);
    expect(find.text('最多点击'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.text('书架'), findsWidgets);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
  });

  testWidgets('catalog search and filters narrow fixture results', (
    tester,
  ) async {
    await pumpShell(tester);

    final search = find.byKey(const ValueKey('discover-search-field'));
    await tester.scrollUntilVisible(
      search,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(search, '齿轮图书馆');
    await tester.pumpAndSettle();
    expect(find.text('找到 1 部小说'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('discover-filters-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('filter-translation-Sakura')),
      findsOneWidget,
    );
  });

  testWidgets('committed remote search results remain authoritative', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remoteMatch = CatalogNovel(
      id: 'remote-author-match',
      chineseTitle: '服务返回的作品',
      japaneseTitle: 'サービス結果',
      source: 'Syosetu',
      publicationState: NovelPublicationState.unknown,
      tags: const [],
      translationCoverage: const [],
      declaredChapterCount: 1,
    );
    var novels = <CatalogNovel>[];

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: DiscoverScreen(
              novels: novels,
              catalogAvailability: CatalogAvailability.available,
              onOpenNovel: (_) {},
              onOpenRankings: () {},
              onCriteriaRequested: (criteria) {
                expect(criteria.search, '服务端作者名');
                setState(() => novels = [remoteMatch]);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey('discover-search-field'));
    await tester.scrollUntilVisible(
      search,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(search);
    await tester.enterText(search, '服务端作者名');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('catalog-card-remote-author-match')),
      findsOneWidget,
    );
    expect(find.text('已加载 1 部小说'), findsOneWidget);
  });

  testWidgets('remote catalog controls delegate complete typed criteria', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <CatalogCriteria>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            novels: fixtureCatalogNovels,
            catalogAvailability: CatalogAvailability.available,
            onOpenNovel: (_) {},
            onOpenRankings: () {},
            onCriteriaRequested: requests.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final filters = find.byKey(const ValueKey('discover-filters-button'));
    await tester.scrollUntilVisible(
      filters,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(filters);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-source-Kakuyomu')));
    await tester.pump();
    expect(requests.last.source, 'Kakuyomu');

    await tester.tap(find.byKey(const ValueKey('filter-state-completed')));
    await tester.pump();
    expect(requests.last.publicationState, NovelPublicationState.completed);

    await tester.tap(find.byKey(const ValueKey('filter-translation-Sakura')));
    await tester.pump();
    expect(requests.last.translationSource, 'Sakura');

    await tester.tap(find.byKey(const ValueKey('catalog-sort-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多点击').last);
    await tester.pumpAndSettle();
    expect(requests.last.sort, CatalogSort.mostClicked);

    final tag = find.byKey(
      ValueKey('catalog-tag-${fixtureCatalogNovels.first.id}-幻想'),
    );
    await tester.scrollUntilVisible(
      tag,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tag);
    await tester.pump();
    expect(requests.last.exactTag, '幻想');
    expect(requests.last.source, 'Kakuyomu');
    expect(requests.last.publicationState, NovelPublicationState.completed);
    expect(requests.last.translationSource, 'Sakura');
    expect(requests.last.sort, CatalogSort.mostClicked);
  });

  testWidgets('known remote catalog total replaces loaded-page wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            novels: fixtureCatalogNovels.take(1).toList(),
            catalogAvailability: CatalogAvailability.available,
            catalogTotalCount: 37,
            onOpenNovel: (_) {},
            onOpenRankings: () {},
            onCriteriaRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('找到 37 部小说'), findsOneWidget);
    expect(find.text('已加载 1 部小说'), findsNothing);
  });

  testWidgets('detail author and tag use the remote catalog criteria path', (
    tester,
  ) async {
    final requests = <CatalogCriteria>[];
    await pumpShell(tester, onCatalogCriteriaRequested: requests.add);
    final novel = fixtureCatalogNovels.first;

    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel-author-chip')));
    await tester.pumpAndSettle();
    expect(requests.last.search, novel.author);
    expect(requests.last.sort, CatalogSort.relevance);
    expect(find.byKey(const ValueKey('novelia-shell')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();
    final tag = find.byKey(const ValueKey('novel-detail-tag-幻想'));
    await tester.scrollUntilVisible(tag, 400);
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(requests.last.search, isEmpty);
    expect(requests.last.exactTag, '幻想');
    expect(find.byKey(const ValueKey('novelia-shell')), findsOneWidget);
  });

  testWidgets(
    'unwired detail actions and unknown chapter count stay truthful',
    (tester) async {
      final unknownCount = CatalogNovel(
        id: 'unknown-count',
        chineseTitle: '章节数未知的作品',
        japaneseTitle: '章数不明の作品',
        source: 'Syosetu',
        publicationState: NovelPublicationState.unknown,
        tags: const [],
        translationCoverage: const [],
        originalUrl: Uri.parse('https://example.invalid/unknown-count'),
      );
      await pumpShell(tester, novels: [unknownCount]);

      expect(find.textContaining('0 章'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('open-details-unknown-count')).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-novel-button')), findsNothing);
      expect(
        find.byKey(const ValueKey('open-original-site-button')),
        findsNothing,
      );
      expect(find.text('章节数未知 · 从旧到新'), findsOneWidget);
    },
  );

  testWidgets('wired favorite and original actions remain available', (
    tester,
  ) async {
    CatalogNovel? favorite;
    CatalogNovel? original;
    final novel = fixtureCatalogNovels.first;
    await pumpShell(
      tester,
      onFavoriteRequested: (value) => favorite = value,
      onOpenOriginalRequested: (value) => original = value,
    );

    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-novel-button')));
    expect(favorite, same(novel));

    final originalButton = find.byKey(
      const ValueKey('open-original-site-button'),
    );
    await tester.scrollUntilVisible(originalButton, 500);
    await tester.tap(originalButton);
    expect(original, same(novel));
  });

  testWidgets('opening a filtered result commits local search history', (
    tester,
  ) async {
    List<String>? savedSearches;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: NoveliaShell(
          novels: fixtureCatalogNovels,
          catalogAvailability: CatalogAvailability.available,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onRecentSearchesChanged: (searches) => savedSearches = searches,
          readerBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey('discover-search-field'));
    await tester.scrollUntilVisible(
      search,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(search, '齿轮图书馆');
    await tester.pumpAndSettle();
    final resultNovel = fixtureCatalogNovels.firstWhere(
      (novel) => novel.chineseTitle.contains('齿轮图书馆'),
    );
    await tester.tap(
      find.byKey(ValueKey('open-details-${resultNovel.id}')).last,
    );
    await tester.pumpAndSettle();

    expect(savedSearches, ['齿轮图书馆']);
  });

  testWidgets('auth-required catalog is explicit without hiding cached data', (
    tester,
  ) async {
    await pumpShell(
      tester,
      availability: CatalogAvailability.authenticationRequired,
    );

    expect(
      find.byKey(const ValueKey('catalog-availability-notice')),
      findsOneWidget,
    );
    expect(find.text('实时目录需要登录'), findsOneWidget);
    expect(
      find.byKey(ValueKey('catalog-card-${fixtureCatalogNovels.first.id}')),
      findsWidgets,
    );
  });

  testWidgets('details place chapters before paginated comments with replies', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: NovelDetailsScreen(novel: novel, onOpenReader: (_) {}),
      ),
    );

    final firstChapter = find.byKey(const ValueKey('chapter-chapter-1'));
    await tester.scrollUntilVisible(firstChapter, 500);
    expect(firstChapter, findsOneWidget);

    final comments = find.text('读者评论');
    await tester.scrollUntilVisible(comments, 500);
    expect(find.byKey(const ValueKey('comments-page-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('comment-reply-reply-1')), findsOneWidget);

    final next = find.byKey(const ValueKey('comments-next-page'));
    await tester.scrollUntilVisible(next, 300);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comments-page-2')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('novel-comment-comment-3')),
      findsOneWidget,
    );
  });

  testWidgets('remote comments omit an unavailable total count', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: NovelDetailsScreen(
          novel: novel,
          onOpenReader: (_) {},
          commentPageLoader: (_, _) => Future.value(
            NovelCommentPage(
              pageNumber: 1,
              totalPages: 2,
              totalComments: null,
              comments: [novel.comments.first],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final summary = find.byKey(const ValueKey('comments-summary'));
    await tester.scrollUntilVisible(summary, 500);

    expect(tester.widget<Text>(summary).data, '共 2 页');
  });

  testWidgets('whole-novel download awaits once and reports async failure', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    final download = Completer<void>();
    var requests = 0;
    await pumpShell(
      tester,
      onDownloadRequested: (_) {
        requests += 1;
        return download.future;
      },
    );
    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('download-novel-button'));
    await tester.tap(button);
    await tester.pump();
    expect(requests, 1);
    expect(
      find.byKey(const ValueKey('download-novel-loading')),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pump();
    expect(requests, 1);

    download.completeError(StateError('fixture download failure'));
    await tester.pumpAndSettle();
    expect(find.text('离线下载创建失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-novel-loading')), findsNothing);
  });

  testWidgets('chapter action crosses the readerBuilder boundary with anchor', (
    tester,
  ) async {
    ReadingPosition? openedPosition;
    await pumpShell(
      tester,
      readerBuilder: (_, data) {
        openedPosition = data.initialPosition;
        return Scaffold(
          body: Text(
            data.novel.chineseTitle,
            key: const ValueKey('fixture-reader-route'),
          ),
        );
      },
    );

    await tester.tap(
      find
          .byKey(ValueKey('open-details-${fixtureCatalogNovels.first.id}'))
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('novel-details-${fixtureCatalogNovels.first.id}')),
      findsOneWidget,
    );

    final chapter = find.byKey(const ValueKey('chapter-chapter-2'));
    await tester.scrollUntilVisible(chapter, 500);
    await tester.tap(chapter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fixture-reader-route')), findsOneWidget);
    expect(openedPosition?.chapterId, 'chapter-2');
    expect(openedPosition?.blockId, 'c2-0');
  });

  testWidgets('outline details expose loading, error, and retry hydration', (
    tester,
  ) async {
    final hydrated = fixtureCatalogNovels.first;
    final outline = _outlineFrom(hydrated);
    final firstAttempt = Completer<CatalogNovel>();
    var attempts = 0;

    await pumpShell(
      tester,
      novels: [outline],
      novelDetailsLoader: (_) {
        attempts += 1;
        return attempts == 1
            ? firstAttempt.future
            : Future<CatalogNovel>.value(hydrated);
      },
    );

    expect(find.textContaining('${hydrated.chapterCount} 章'), findsWidgets);
    expect(find.textContaining('null'), findsNothing);
    await tester.tap(find.byKey(ValueKey('open-details-${outline.id}')).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('novel-details-loading')), findsOneWidget);

    firstAttempt.completeError(StateError('fixture detail failure'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-details-error')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('retry-novel-details')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('novel-details-${hydrated.id}')),
      findsOneWidget,
    );
    expect(attempts, 2);
  });

  testWidgets('reader loader retries and opens a bounded semantic window', (
    tester,
  ) async {
    final hydrated = fixtureCatalogNovels.first;
    final selected = hydrated.readerNovel!.chapters[1];
    final boundedNovel = ReaderNovel(
      id: hydrated.id,
      chineseTitle: hydrated.chineseTitle,
      japaneseTitle: hydrated.japaneseTitle,
      author: hydrated.author ?? '',
      chapters: [selected],
    );
    final firstAttempt = Completer<ReaderLaunchData>();
    var attempts = 0;
    NovelChapter? loaderChapter;
    ReaderNovel? openedWindow;
    ReadingPosition? openedPosition;
    ReaderChapterDataSource? openedDataSource;
    final chapterDataSource = ReaderChapterDataSource(
      catalog: hydrated.readerNovel!.chapters
          .map(ReaderChapterCatalogEntry.fromChapter)
          .toList(),
      loadAround: (_) => Future.error(StateError('not used')),
      loadAdjacent: (_) => Future.error(StateError('not used')),
    );

    await pumpShell(
      tester,
      novels: [hydrated],
      readerLaunchLoader: (novel, chapter, position) {
        attempts += 1;
        loaderChapter = chapter;
        return attempts == 1
            ? firstAttempt.future
            : Future<ReaderLaunchData>.value(
                ReaderLaunchData(
                  novel: boundedNovel,
                  dataSource: chapterDataSource,
                ),
              );
      },
      onReaderOpened: (catalog, data) {
        openedWindow = data.novel;
        openedPosition = data.initialPosition;
        openedDataSource = data.dataSource;
      },
    );

    await tester.tap(find.byKey(ValueKey('open-details-${hydrated.id}')).first);
    await tester.pumpAndSettle();
    final chapter = find.byKey(ValueKey('chapter-${selected.id}'));
    await tester.scrollUntilVisible(chapter, 500);
    await tester.tap(chapter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('reader-launch-loading')), findsOneWidget);
    expect(loaderChapter?.id, selected.id);

    firstAttempt.completeError(StateError('fixture chapter failure'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-launch-error')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-reader-launch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fixture-reader-route')), findsOneWidget);
    expect(openedWindow?.chapters, hasLength(1));
    expect(openedPosition?.chapterId, selected.id);
    expect(openedPosition?.blockId, selected.blocks.first.id);
    expect(openedDataSource, same(chapterDataSource));
    expect(attempts, 2);
  });

  testWidgets('remote comments replace exactly one service page at a time', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    final firstPage = Completer<NovelCommentPage>();
    final requestedPages = <int>[];
    final allComments = novel.comments;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: NovelDetailsScreen(
          novel: novel,
          onOpenReader: (_) {},
          commentPageLoader: (_, pageNumber) {
            requestedPages.add(pageNumber);
            if (pageNumber == 1) return firstPage.future;
            return Future<NovelCommentPage>.value(
              NovelCommentPage(
                pageNumber: 2,
                totalPages: 2,
                totalComments: 3,
                comments: [allComments[2]],
              ),
            );
          },
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('读者评论'), 500);
    expect(find.byKey(const ValueKey('comments-page-loading')), findsOneWidget);
    firstPage.complete(
      NovelCommentPage(
        pageNumber: 1,
        totalPages: 2,
        totalComments: 3,
        comments: allComments.take(2).toList(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comments-page-1')), findsOneWidget);
    expect(
      find.byKey(ValueKey('novel-comment-${allComments.first.id}')),
      findsOneWidget,
    );

    final next = find.byKey(const ValueKey('comments-next-page'));
    await tester.scrollUntilVisible(next, 300);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comments-page-2')), findsOneWidget);
    expect(
      find.byKey(ValueKey('novel-comment-${allComments.first.id}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('novel-comment-${allComments[2].id}')),
      findsOneWidget,
    );
    expect(requestedPages, [1, 2]);
  });
}

CatalogNovel _outlineFrom(CatalogNovel hydrated) {
  return CatalogNovel(
    id: hydrated.id,
    chineseTitle: hydrated.chineseTitle,
    japaneseTitle: hydrated.japaneseTitle,
    source: hydrated.source,
    publicationState: hydrated.publicationState,
    tags: hydrated.tags,
    translationCoverage: hydrated.translationCoverage,
    declaredChapterCount: hydrated.chapterCount,
    originalUrl: hydrated.originalUrl,
  );
}
