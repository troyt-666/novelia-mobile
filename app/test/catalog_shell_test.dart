import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/account/remote_novel_list_screen.dart';
import 'package:jfzreader/features/account/account_screen.dart';
import 'package:jfzreader/features/discover/catalog_card.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/discover/discover_screen.dart';
import 'package:jfzreader/features/discover/rankings_screen.dart';
import 'package:jfzreader/features/novel_details/novel_details_screen.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';

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
    FutureOr<void> Function()? onDiscoveryRefreshRequested,
    ValueChanged<CatalogNovel>? onFavoriteRequested,
    AccountSessionSnapshot accountSession =
        const AccountSessionSnapshot.signedOut(),
    RemoteFavoritesViewModel remoteFavorites =
        const RemoteFavoritesViewModel.unavailable(),
    FavoriteToFolderRequested? onFavoriteToFolderRequested,
    AccountLogin? onAccountLogin,
    FavoriteFolderPageLoader? favoriteFolderLoader,
    RemoteNovelPageLoader? readingHistoryLoader,
    ValueChanged<CatalogNovel>? onOpenOriginalRequested,
    List<LibraryContinuedRead> continuedReads = const [],
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
          onDiscoveryRefreshRequested: onDiscoveryRefreshRequested,
          onFavoriteRequested: onFavoriteRequested,
          accountSession: accountSession,
          remoteFavorites: remoteFavorites,
          onFavoriteToFolderRequested: onFavoriteToFolderRequested,
          onAccountLogin: onAccountLogin,
          favoriteFolderLoader: favoriteFolderLoader,
          readingHistoryLoader: readingHistoryLoader,
          onOpenOriginalRequested: onOpenOriginalRequested,
          continuedReads: continuedReads,
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

  testWidgets('exposes separate Discover, Search, Library, and Settings tabs', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.text('发现'), findsWidgets);
    expect(find.text('继续阅读'), findsNothing);
    expect(find.text('最多点击'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);
    expect(find.byKey(const ValueKey('discover-search-field')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discover-search-field')), findsOneWidget);
    expect(find.text('搜索条件'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.text('书架'), findsWidgets);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
  });

  testWidgets('shell adapts between phone, fold, and desktop widths', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shell-navigation-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);

    tester.view.physicalSize = const Size(673, 840);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shell-navigation-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shell-navigation-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-navigation-bar')), findsNothing);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);

    tester.view.physicalSize = const Size(430, 932);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shell-navigation-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-folders-grid')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reselecting Discovery refreshes its feed', (tester) async {
    var refreshCount = 0;
    await pumpShell(
      tester,
      onDiscoveryRefreshRequested: () async => refreshCount += 1,
    );

    await tester.tap(find.byKey(const ValueKey('nav-discover')));
    await tester.pump();

    expect(refreshCount, 1);
  });

  testWidgets('Discovery supports pull refresh and requests its next page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var refreshCount = 0;
    final requestedSorts = <CatalogSort>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            mode: DiscoverScreenMode.discovery,
            novels: fixtureCatalogNovels,
            catalogAvailability: CatalogAvailability.available,
            onOpenNovel: (_) {},
            onOpenRankings: () {},
            onRefreshRequested: () async => refreshCount += 1,
            onDiscoveryLoadMoreRequested: (sort) async {
              requestedSorts.add(sort);
            },
            recentlyUpdatedHasMore: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 360),
      1000,
    );
    await tester.pumpAndSettle();
    expect(refreshCount, 1);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pump();
    expect(requestedSorts, contains(CatalogSort.recentlyUpdated));
  });

  testWidgets('search sources default to checked multi-select chips', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();

    final searchBar = tester.widget<SearchBar>(
      find.byKey(const ValueKey('discover-search-field')),
    );
    expect(searchBar.elevation?.resolve({}), 0);
    expect(searchBar.constraints?.minHeight, 48);
    expect(searchBar.constraints?.maxHeight, 48);

    final filters = find.byKey(const ValueKey('discover-filters-button'));
    await tester.scrollUntilVisible(
      filters,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(filters);
    await tester.pumpAndSettle();

    for (final source in catalogSourceValues) {
      final chip = tester.widget<FilterChip>(
        find.byKey(ValueKey('filter-source-$source')),
      );
      expect(chip.selected, isTrue);
      expect((chip.label as Text).data, isNot('全部'));
    }
  });

  testWidgets('discovery exposes every tag and opens its catalog results', (
    tester,
  ) async {
    const tags = ['R15', '残酷描写', 'ブルーアーカイブ', 'アンチ・ヘイト', '転生', '学園'];
    final novel = CatalogNovel(
      id: 'six-tag-novel',
      chineseTitle: '显示全部标签的小说',
      japaneseTitle: 'すべてのタグを表示する小説',
      source: 'Hameln',
      publicationState: NovelPublicationState.ongoing,
      updatedAt: DateTime.utc(2026, 8, 18),
      tags: tags,
      translationCoverage: const [],
      declaredChapterCount: 1,
    );
    await pumpShell(tester, novels: [novel]);

    for (final tag in tags) {
      expect(
        find.byKey(ValueKey('catalog-tag-${novel.id}-$tag')),
        findsOneWidget,
      );
    }

    final tag = tags.last;
    final tagFinder = find.byKey(ValueKey('catalog-tag-${novel.id}-$tag'));
    expect(tester.widget<ActionChip>(tagFinder).onPressed, isNotNull);
    await tester.scrollUntilVisible(
      tagFinder,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tagFinder);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discover-search-field')), findsOneWidget);
    expect(find.text('标签“$tag” · 1 部'), findsOneWidget);
  });

  testWidgets('favorite folders and Reading History open remote pages', (
    tester,
  ) async {
    final profile = ReaderAccountProfile(
      username: 'reader',
      role: 'member',
      issuedAt: DateTime.utc(2026, 8, 18),
      createdAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2026, 8, 19),
    );
    final favoriteRequests = <(String, int)>[];
    final historyRequests = <int>[];
    final favoriteNovel = fixtureCatalogNovels.first.copyWith(isFavorite: true);
    await pumpShell(
      tester,
      accountSession: AccountSessionSnapshot.signedIn(profile),
      remoteFavorites: RemoteFavoritesViewModel.available(const [
        LibraryFavoriteFolder(id: 'default', title: '默认收藏夹'),
      ]),
      favoriteFolderLoader: (folderId, page) async {
        favoriteRequests.add((folderId, page));
        return RemoteNovelPageView(
          novels: [favoriteNovel],
          pageNumber: page,
          totalPages: 1,
        );
      },
      onFavoriteToFolderRequested: (_, _) async {},
      readingHistoryLoader: (page) async {
        historyRequests.add(page);
        return RemoteNovelPageView(
          novels: [fixtureCatalogNovels[1]],
          pageNumber: page,
          totalPages: 1,
        );
      },
    );

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-folder-default')));
    await tester.pumpAndSettle();
    expect(find.text(favoriteNovel.chineseTitle), findsOneWidget);
    expect(favoriteRequests, [('default', 1)]);

    await tester.tap(find.byKey(ValueKey('open-details-${favoriteNovel.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-icon-solid')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-icon-hollow')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    final favoriteTag = favoriteNovel.tags.first;
    final favoriteTagFinder = find.byKey(
      ValueKey('catalog-tag-${favoriteNovel.id}-$favoriteTag'),
    );
    await tester.scrollUntilVisible(favoriteTagFinder, 300);
    await tester.tap(favoriteTagFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discover-search-field')), findsOneWidget);
    expect(find.text('标签“$favoriteTag” · 1 部'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读历史'));
    await tester.pumpAndSettle();
    expect(find.text(fixtureCatalogNovels[1].chineseTitle), findsOneWidget);
    expect(historyRequests, [1]);
  });

  testWidgets('Discover continued reading resumes and exposes novel details', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    final chapter = novel.readerNovel!.chapters.first;
    final position = ReadingPosition(
      chapterId: chapter.id,
      blockId: chapter.blocks.first.id,
    );
    ReadingPosition? openedPosition;
    var openedAtChapterTitle = true;
    await pumpShell(
      tester,
      continuedReads: [
        LibraryContinuedRead(novel: novel, position: position, progress: 0.25),
      ],
      onReaderOpened: (_, data) {
        openedPosition = data.initialPosition;
        openedAtChapterTitle = data.startAtChapterTitle;
      },
    );

    final details = find.byKey(ValueKey('continued-details-${novel.id}'));
    expect(details, findsOneWidget);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('novel-details-${novel.id}')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('continue-reading-${novel.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fixture-reader-route')), findsOneWidget);
    expect(openedPosition, position);
    expect(openedAtChapterTitle, isFalse);
  });

  testWidgets('most-clicked cards fit long live metadata on Android widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final liveNovel = CatalogNovel(
      id: 'hameln/live-overflow',
      chineseTitle: '转生成为和风奇幻忧郁黄游的无名战斗员，周遭的女孩们',
      japaneseTitle: '和風ファンタジーな鬱エロゲーの無名戦闘員',
      source: 'Hameln',
      publicationState: NovelPublicationState.ongoing,
      declaredChapterCount: 260,
      tags: const [],
      translationCoverage: const [
        TranslationCoverage(
          source: '有道',
          translatedChapters: 260,
          totalChapters: 260,
        ),
        TranslationCoverage(
          source: 'GPT',
          translatedChapters: 255,
          totalChapters: 260,
        ),
        TranslationCoverage(
          source: 'Sakura',
          translatedChapters: 258,
          totalChapters: 260,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: DiscoverScreen(
              novels: [liveNovel],
              mostClickedNovels: [liveNovel],
              catalogAvailability: CatalogAvailability.available,
              onOpenNovel: (_) {},
              onOpenRankings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('most-clicked-shelf')), findsOneWidget);
  });

  testWidgets('catalog search and filters narrow fixture results', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();

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
    expect(find.byKey(const ValueKey('filter-translation-有道')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('filter-translation-Sakura')),
      findsOneWidget,
    );
    expect(find.text('成为小说家吧'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-state-ongoing')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('filter-state-completed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('filter-state-shortStory')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('filter-level-general')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-level-r18')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('filter-translation-GPT')),
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
              mode: DiscoverScreenMode.search,
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

  testWidgets('initial remote search shows loading instead of empty results', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            mode: DiscoverScreenMode.search,
            novels: const [],
            catalogAvailability: CatalogAvailability.available,
            catalogLoading: true,
            onOpenNovel: (_) {},
            onOpenRankings: () {},
            onCriteriaRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('catalog-search-loading')),
      findsOneWidget,
    );
    expect(find.text('正在搜索…'), findsOneWidget);
    expect(find.text('没有匹配的小说'), findsNothing);
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
            mode: DiscoverScreenMode.search,
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
    expect(requests.last.sources, isNot(contains('Kakuyomu')));
    expect(requests.last.sources, hasLength(catalogSourceValues.length - 1));

    await tester.tap(find.byKey(const ValueKey('filter-source-Syosetu')));
    await tester.pump();
    expect(requests.last.sources, isNot(contains('Syosetu')));
    expect(requests.last.sources, hasLength(catalogSourceValues.length - 2));

    await tester.tap(find.byKey(const ValueKey('filter-source-Kakuyomu')));
    await tester.pump();
    expect(requests.last.sources, contains('Kakuyomu'));

    await tester.tap(find.byKey(const ValueKey('filter-state-completed')));
    await tester.pump();
    expect(requests.last.publicationState, NovelPublicationState.completed);

    await tester.tap(find.byKey(const ValueKey('filter-level-r18')));
    await tester.pump();
    expect(requests.last.contentLevel, CatalogContentLevel.r18);
    await tester.tap(find.byKey(const ValueKey('filter-level-all')));
    await tester.pump();
    expect(requests.last.contentLevel, CatalogContentLevel.all);

    await tester.tap(find.byKey(const ValueKey('filter-translation-Sakura')));
    await tester.pump();
    expect(requests.last.translationSource, 'Sakura');

    await tester.tap(find.byKey(const ValueKey('catalog-sort-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击').last);
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
    expect(requests.last.sources, contains('Kakuyomu'));
    expect(requests.last.sources, isNot(contains('Syosetu')));
    expect(requests.last.publicationState, NovelPublicationState.completed);
    expect(requests.last.contentLevel, CatalogContentLevel.all);
    expect(requests.last.translationSource, 'Sakura');
    expect(requests.last.sort, CatalogSort.mostClicked);
  });

  testWidgets('known remote catalog total replaces loaded-page wording', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverScreen(
            mode: DiscoverScreenMode.search,
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
    expect(find.byKey(const ValueKey('favorite-icon-hollow')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favorite-novel-button')));
    await tester.pumpAndSettle();
    expect(favorite, same(novel));
    expect(find.byKey(const ValueKey('favorite-icon-solid')), findsOneWidget);

    final originalButton = find.byKey(
      const ValueKey('open-original-site-button'),
    );
    await tester.scrollUntilVisible(originalButton, 500);
    await tester.tap(originalButton);
    expect(original, same(novel));
  });

  testWidgets('multiple remote folders require explicit confirmation', (
    tester,
  ) async {
    final profile = ReaderAccountProfile(
      username: 'reader',
      role: 'member',
      issuedAt: DateTime.utc(2026, 8, 18),
      createdAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2026, 8, 19),
    );
    CatalogNovel? favorite;
    String? folderId;
    final novel = fixtureCatalogNovels.first;
    await pumpShell(
      tester,
      accountSession: AccountSessionSnapshot.signedIn(profile),
      remoteFavorites: RemoteFavoritesViewModel.available(const [
        LibraryFavoriteFolder(id: 'default', title: '默认收藏夹'),
        LibraryFavoriteFolder(id: 'later', title: '以后读'),
      ]),
      onFavoriteToFolderRequested: (value, selectedFolderId) {
        favorite = value;
        folderId = selectedFolderId;
      },
    );

    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-novel-button')));
    await tester.pumpAndSettle();
    expect(find.text('收藏到…'), findsOneWidget);
    expect(favorite, isNull);

    await tester.tap(
      find.byKey(const ValueKey('favorite-folder-choice-later')),
    );
    await tester.tap(find.byKey(const ValueKey('confirm-favorite-folder')));
    await tester.pumpAndSettle();

    expect(favorite, same(novel));
    expect(folderId, 'later');
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
    await tester.tap(find.byKey(const ValueKey('nav-search')));
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

  testWidgets('chapter catalog starts folded and can expand and fold again', (
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
    final toggle = find.byKey(const ValueKey('toggle-chapters-button'));
    await tester.scrollUntilVisible(toggle, 500);
    expect(firstChapter, findsNothing);
    expect(find.text('展开目录'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(firstChapter, 500);
    expect(firstChapter, findsOneWidget);
    expect(find.text('收起目录'), findsOneWidget);

    await tester.scrollUntilVisible(toggle, 500);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(firstChapter, findsNothing);
    expect(find.text('展开目录'), findsOneWidget);
  });

  testWidgets('folded chapters keep paginated comments readily reachable', (
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

    final comments = find.text('读者评论');
    await tester.scrollUntilVisible(comments, 500);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chapter-chapter-1')), findsNothing);
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
    var openedAtChapterTitle = false;
    await pumpShell(
      tester,
      readerBuilder: (_, data) {
        openedPosition = data.initialPosition;
        openedAtChapterTitle = data.startAtChapterTitle;
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

    final toggle = find.byKey(const ValueKey('toggle-chapters-button'));
    await tester.scrollUntilVisible(toggle, 500);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final chapter = find.byKey(const ValueKey('chapter-chapter-2'));
    await tester.scrollUntilVisible(chapter, 500);
    await tester.tap(chapter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fixture-reader-route')), findsOneWidget);
    expect(openedPosition?.chapterId, 'chapter-2');
    expect(openedPosition?.blockId, 'c2-0');
    expect(openedAtChapterTitle, isTrue);
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
    final toggle = find.byKey(const ValueKey('toggle-chapters-button'));
    await tester.scrollUntilVisible(toggle, 500);
    await tester.tap(toggle);
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
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
    await tester.pump();
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

  testWidgets('unavailable stored account does not open a replacement login', (
    tester,
  ) async {
    final novel = fixtureCatalogNovels.first;
    await pumpShell(
      tester,
      accountSession: AccountSessionSnapshot.unavailable(
        ReaderAccountProfile(
          username: 'alice',
          role: 'member',
          issuedAt: DateTime.utc(2026, 8, 1),
          createdAt: DateTime.utc(2026, 8, 1),
          expiresAt: DateTime.utc(2026, 9, 1),
        ),
        message: 'offline',
      ),
      onAccountLogin: ({required username, required password}) async {},
      onFavoriteToFolderRequested: (_, _) async {},
    );
    await tester.tap(find.byKey(ValueKey('open-details-${novel.id}')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-novel-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AccountScreen), findsNothing);
    expect(find.textContaining('请到设置中重试或退出后重新登录'), findsOneWidget);
  });

  testWidgets('rankings keep filters and apply period in fixture mode', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('open-rankings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rankings-screen')), findsOneWidget);
    Finder rankingCards() => find.descendant(
      of: find.byKey(const ValueKey('rankings-screen')),
      matching: find.byType(CatalogNovelCard),
    );
    final overallCount = rankingCards().evaluate().length;
    expect(overallCount, greaterThan(1));

    await tester.tap(find.byKey(const ValueKey('ranking-period-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日榜').last);
    await tester.pumpAndSettle();
    expect(rankingCards().evaluate().length, lessThan(overallCount));

    await tester.tap(find.byKey(const ValueKey('rankings-close-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-rankings-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-rankings-button')));
    await tester.pumpAndSettle();
    expect(rankingCards().evaluate().length, lessThan(overallCount));
  });

  testWidgets('remote rankings append pages instead of replacing them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final queries = <RankingsQuery>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RankingsScreen(
          novels: const [],
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
          loader: (query) async {
            queries.add(query);
            return RankingPageView(
              novels: [fixtureCatalogNovels[query.pageNumber - 1]],
              pageNumber: query.pageNumber,
              totalPages: 2,
              description: 'test rankings',
              firstRank: query.pageNumber,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(queries.map((query) => query.pageNumber), [1, 2]);
    expect(find.text(fixtureCatalogNovels[0].chineseTitle), findsOneWidget);
    expect(find.text(fixtureCatalogNovels[1].chineseTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('rankings-previous-page')), findsNothing);
  });

  testWidgets(
    'remote rankings expose supported sources and clear Kakuyomu state',
    (tester) async {
      final queries = <RankingsQuery>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RankingsScreen(
            novels: [fixtureCatalogNovels[2]],
            onOpenNovel: (_) {},
            onTagSelected: (_) {},
            loader: (query) async {
              queries.add(query);
              return RankingPageView(
                novels: [fixtureCatalogNovels.first],
                pageNumber: 1,
                totalPages: 1,
                description: 'test rankings',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(queries.single.source, 'Syosetu');
      await tester.tap(find.byKey(const ValueKey('ranking-source-filter')));
      await tester.pumpAndSettle();
      expect(find.text('Kakuyomu'), findsWidgets);
      expect(find.text('Novelup'), findsNothing);
      expect(find.text('全部来源'), findsNothing);
      await tester.tap(find.text('Syosetu').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ranking-state-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(NovelPublicationState.completed.label).last);
      await tester.pumpAndSettle();
      expect(queries.last.publicationState, NovelPublicationState.completed);

      await tester.tap(find.byKey(const ValueKey('ranking-source-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kakuyomu').last);
      await tester.pumpAndSettle();

      expect(queries.last.source, 'Kakuyomu');
      expect(queries.last.publicationState, isNull);
      expect(find.byKey(const ValueKey('ranking-state-filter')), findsNothing);
    },
  );
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
