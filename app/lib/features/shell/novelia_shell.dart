import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../discover/catalog_models.dart';
import '../discover/catalog_search_results_screen.dart';
import '../discover/discover_screen.dart';
import '../discover/rankings_screen.dart';
import '../novel_details/novel_details_loader_screen.dart';
import '../novel_details/novel_details_screen.dart';
import 'library_screen.dart';
import 'reader_launch_loader_screen.dart';
import 'settings_screen.dart';
import 'shell_view_models.dart';

typedef ReaderPageBuilder =
    Widget Function(BuildContext context, ReaderLaunchData launchData);

typedef ReaderRouteOpened =
    void Function(CatalogNovel catalogNovel, ReaderLaunchData launchData);

typedef NovelDownloadRequested =
    FutureOr<void> Function(CatalogNovel catalogNovel);

class NoveliaShell extends StatefulWidget {
  const NoveliaShell({
    required this.novels,
    required this.readerBuilder,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.catalogAvailability,
    this.novelDetailsLoader,
    this.readerLaunchLoader,
    this.commentPageLoader,
    this.onFavoriteRequested,
    this.onDownloadRequested,
    this.onOpenOriginalRequested,
    this.onLoginRequested,
    this.onReleasesRequested,
    this.continuedReads = const [],
    this.protectedDownloads = const [],
    this.bookmarks = const [],
    this.remoteFavorites = const RemoteFavoritesViewModel.unavailable(),
    this.storageSummary = const OfflineStorageSummary(
      cacheBytes: 0,
      offlineDownloadBytes: 0,
      cacheChapterCount: 0,
      offlineDownloadChapterCount: 0,
      perNovel: [],
    ),
    this.cacheLimitBytes,
    this.initialCatalogCriteria = const CatalogCriteria(),
    this.onCatalogCriteriaRequested,
    this.onCatalogSearchRequested,
    this.onCatalogLoadMoreRequested,
    this.catalogTotalCount,
    this.catalogHasMore = false,
    this.catalogLoadingMore = false,
    this.catalogLoadMoreFailed = false,
    this.rankingsLoader,
    this.mostClickedNovels = const [],
    this.initialDestination = 0,
    this.initialRecentSearches = const [],
    this.onDestinationChanged,
    this.onRecentSearchesChanged,
    this.initialReaderNovelId,
    this.initialReaderPosition,
    this.onReaderOpened,
    this.onReaderClosed,
    super.key,
  });

  final List<CatalogNovel> novels;
  final ReaderPageBuilder readerBuilder;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final CatalogAvailability catalogAvailability;
  final NovelDetailsLoader? novelDetailsLoader;
  final ReaderLaunchLoader? readerLaunchLoader;
  final NovelCommentPageLoader? commentPageLoader;
  final ValueChanged<CatalogNovel>? onFavoriteRequested;
  final NovelDownloadRequested? onDownloadRequested;
  final ValueChanged<CatalogNovel>? onOpenOriginalRequested;
  final VoidCallback? onLoginRequested;
  final VoidCallback? onReleasesRequested;
  final List<LibraryContinuedRead> continuedReads;
  final List<LibraryProtectedDownload> protectedDownloads;
  final List<LibraryBookmarkItem> bookmarks;
  final RemoteFavoritesViewModel remoteFavorites;
  final OfflineStorageSummary storageSummary;
  final int? cacheLimitBytes;
  final CatalogCriteria initialCatalogCriteria;
  final CatalogCriteriaRequested? onCatalogCriteriaRequested;

  /// Legacy search-only boundary retained while composition roots migrate to
  /// [onCatalogCriteriaRequested].
  final FutureOr<void> Function(String query)? onCatalogSearchRequested;
  final FutureOr<void> Function()? onCatalogLoadMoreRequested;
  final int? catalogTotalCount;
  final bool catalogHasMore;
  final bool catalogLoadingMore;
  final bool catalogLoadMoreFailed;
  final RankingsLoader? rankingsLoader;
  final List<CatalogNovel> mostClickedNovels;
  final int initialDestination;
  final List<String> initialRecentSearches;
  final ValueChanged<int>? onDestinationChanged;
  final ValueChanged<List<String>>? onRecentSearchesChanged;
  final String? initialReaderNovelId;
  final ReadingPosition? initialReaderPosition;
  final ReaderRouteOpened? onReaderOpened;
  final VoidCallback? onReaderClosed;

  @override
  State<NoveliaShell> createState() => _NoveliaShellState();
}

class _NoveliaShellState extends State<NoveliaShell> {
  late int _destination = widget.initialDestination.clamp(0, 2);
  late final List<String> _recentSearches = List.of(
    widget.initialRecentSearches.take(8),
  );
  late CatalogCriteria _catalogCriteria = widget.initialCatalogCriteria;
  var _restoringInitialReader = false;

  @override
  void initState() {
    super.initState();
    final initialNovelId = widget.initialReaderNovelId;
    if (initialNovelId == null) return;
    final initialNovel = widget.novels
        .where((novel) => novel.id == initialNovelId)
        .firstOrNull;
    if (initialNovel == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReaderClosed?.call();
      });
      return;
    }
    _restoringInitialReader = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openReader(
          initialNovel,
          null,
          requestedPosition: widget.initialReaderPosition,
        );
      }
    });
  }

  void _selectDestination(int value) {
    setState(() => _destination = value);
    widget.onDestinationChanged?.call(value);
  }

  void _notifyRecentSearchesChanged() {
    widget.onRecentSearchesChanged?.call(List.unmodifiable(_recentSearches));
  }

  void _rememberSearch(String query) {
    setState(() {
      _recentSearches.remove(query);
      _recentSearches.insert(0, query);
      if (_recentSearches.length > 8) _recentSearches.removeLast();
    });
    _notifyRecentSearchesChanged();
  }

  Future<void> _requestCatalogCriteria(CatalogCriteria criteria) async {
    if (_catalogCriteria != criteria && mounted) {
      setState(() => _catalogCriteria = criteria);
    }
    final callback = widget.onCatalogCriteriaRequested;
    if (callback != null) await callback(criteria);
  }

  void _openRemoteCatalogCriteria(CatalogCriteria criteria) {
    if (_destination != 0 || _catalogCriteria != criteria) {
      setState(() {
        _destination = 0;
        _catalogCriteria = criteria;
      });
      widget.onDestinationChanged?.call(0);
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    unawaited(_requestCatalogCriteria(criteria).catchError((_) {}));
  }

  void _showFixtureAction(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openReader(
    CatalogNovel catalogNovel,
    NovelChapter? chapter, {
    ReadingPosition? requestedPosition,
  }) async {
    final fixtureNovel = catalogNovel.readerNovel;
    ReaderLaunchData? synchronousData;
    if (widget.readerLaunchLoader == null &&
        fixtureNovel != null &&
        _hasReadableContent(fixtureNovel, requestedChapter: chapter)) {
      final initialPosition = _resolveReaderPosition(
        fixtureNovel,
        requestedPosition: requestedPosition,
        requestedChapter: chapter,
      );
      synchronousData = ReaderLaunchData(
        novel: fixtureNovel,
        initialPosition: initialPosition,
      );
      widget.onReaderOpened?.call(catalogNovel, synchronousData);
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) {
          if (synchronousData case final data?) {
            return widget.readerBuilder(routeContext, data);
          }
          return ReaderLaunchLoaderScreen(
            load: () =>
                _loadReaderWindow(catalogNovel, chapter, requestedPosition),
            onLoaded: (data) {
              if (!mounted) return;
              widget.onReaderOpened?.call(catalogNovel, data);
            },
            builder: widget.readerBuilder,
          );
        },
        settings: RouteSettings(name: '/reader/${catalogNovel.id}'),
      ),
    );
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (_restoringInitialReader) {
      setState(() => _restoringInitialReader = false);
    }
    widget.onReaderClosed?.call();
  }

  bool _hasReadableContent(
    ReaderNovel novel, {
    NovelChapter? requestedChapter,
  }) {
    if (requestedChapter != null) {
      return novel.chapters.any(
        (chapter) =>
            chapter.id == requestedChapter.id && chapter.blocks.isNotEmpty,
      );
    }
    return novel.chapters.any((chapter) => chapter.blocks.isNotEmpty);
  }

  Future<ReaderLaunchData> _loadReaderWindow(
    CatalogNovel novel,
    NovelChapter? selectedChapter,
    ReadingPosition? requestedPosition,
  ) async {
    final loader = widget.readerLaunchLoader;
    if (loader == null) {
      throw StateError('No reader loader is configured for this outline.');
    }
    final loaded = await loader(novel, selectedChapter, requestedPosition);
    if (!mounted) {
      throw StateError('Reader launch was cancelled.');
    }
    if (loaded.novel.id != novel.id) {
      throw StateError('Loaded reader novel ID does not match its outline.');
    }
    final loadedChapter = selectedChapter == null
        ? null
        : loaded.novel.chapters
              .where((chapter) => chapter.id == selectedChapter.id)
              .firstOrNull;
    final resolvedPosition = _resolveReaderPosition(
      loaded.novel,
      requestedPosition: loaded.initialPosition ?? requestedPosition,
      requestedChapter: loadedChapter,
    );
    if (resolvedPosition == null) {
      throw StateError('Reader loader returned no readable chapter blocks.');
    }
    return ReaderLaunchData(
      novel: loaded.novel,
      initialPosition: resolvedPosition,
      dataSource: loaded.dataSource,
    );
  }

  ReadingPosition? _resolveReaderPosition(
    ReaderNovel novel, {
    ReadingPosition? requestedPosition,
    NovelChapter? requestedChapter,
  }) {
    if (requestedPosition != null) {
      final chapter = novel.chapters
          .where((item) => item.id == requestedPosition.chapterId)
          .firstOrNull;
      if (chapter != null) {
        final hasRequestedBlock = chapter.blocks.any(
          (block) => block.id == requestedPosition.blockId,
        );
        if (hasRequestedBlock) return requestedPosition;
        final firstBlock = chapter.blocks.firstOrNull;
        if (firstBlock != null) {
          return ReadingPosition(chapterId: chapter.id, blockId: firstBlock.id);
        }
      }
    }
    if (requestedChapter != null) {
      final firstBlock = requestedChapter.blocks.firstOrNull;
      if (firstBlock != null) {
        return ReadingPosition(
          chapterId: requestedChapter.id,
          blockId: firstBlock.id,
        );
      }
    }
    for (final chapter in novel.chapters) {
      final firstBlock = chapter.blocks.firstOrNull;
      if (firstBlock != null) {
        return ReadingPosition(chapterId: chapter.id, blockId: firstBlock.id);
      }
    }
    return null;
  }

  Future<void> _openNovel(CatalogNovel outline) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => NovelDetailsLoaderScreen(
          outline: outline,
          loader: widget.novelDetailsLoader,
          builder: (context, novel) => NovelDetailsScreen(
            novel: novel,
            commentPageLoader: widget.commentPageLoader,
            onOpenReader: (chapter) => _openReader(novel, chapter),
            onFavorite: widget.onFavoriteRequested == null
                ? null
                : () => widget.onFavoriteRequested!(novel),
            onDownload: () async {
              final callback = widget.onDownloadRequested;
              if (callback != null) {
                try {
                  await callback(novel);
                  if (!mounted) return;
                  _showFixtureAction('已加入离线下载');
                } on Object {
                  if (!mounted) return;
                  _showFixtureAction('离线下载创建失败，请稍后重试');
                }
              } else {
                if (!mounted) return;
                _showFixtureAction('离线下载将在本地数据阶段接入');
              }
            },
            onOpenOriginal:
                novel.originalUrl == null ||
                    widget.onOpenOriginalRequested == null
                ? null
                : () => widget.onOpenOriginalRequested!(novel),
            onAuthorSelected: widget.onCatalogCriteriaRequested == null
                ? (author) => _openSearchResults(
                    '作者：$author',
                    widget.novels
                        .where((item) => item.author == author)
                        .toList(),
                  )
                : (author) => _openRemoteCatalogCriteria(
                    CatalogCriteria(
                      search: author,
                      sort: CatalogSort.relevance,
                    ),
                  ),
            onTagSelected: widget.onCatalogCriteriaRequested == null
                ? (tag) => _openSearchResults(
                    '标签：$tag',
                    widget.novels
                        .where((item) => item.tags.contains(tag))
                        .toList(),
                  )
                : (tag) => _openRemoteCatalogCriteria(
                    CatalogCriteria(exactTag: tag),
                  ),
          ),
        ),
        settings: RouteSettings(name: '/novel/${outline.id}'),
      ),
    );
  }

  Future<void> _openSearchResults(
    String title,
    List<CatalogNovel> novels,
  ) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CatalogSearchResultsScreen(
          title: title,
          novels: novels,
          onOpenNovel: _openNovel,
        ),
        settings: const RouteSettings(name: '/catalog/search'),
      ),
    );
  }

  Future<void> _openRankings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          novels: widget.novels,
          loader: widget.rankingsLoader,
          onOpenNovel: _openNovel,
        ),
        settings: const RouteSettings(name: '/rankings'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_restoringInitialReader) {
      return Scaffold(
        key: const ValueKey('reader-restore-placeholder'),
        body: Center(
          child: Semantics(
            label: '正在恢复阅读位置',
            child: const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      );
    }
    final continuedRead = widget.continuedReads.firstOrNull;
    final pages = [
      DiscoverScreen(
        novels: widget.novels,
        catalogAvailability: widget.catalogAvailability,
        continuedNovel: continuedRead?.novel,
        continuedProgress: continuedRead?.progress,
        onContinueReading: continuedRead == null
            ? null
            : () => _openReader(
                continuedRead.novel,
                null,
                requestedPosition: continuedRead.position,
              ),
        initialCriteria: _catalogCriteria,
        onCriteriaRequested: widget.onCatalogCriteriaRequested == null
            ? null
            : _requestCatalogCriteria,
        onSearchRequested: widget.onCatalogSearchRequested,
        onLoadMoreRequested: widget.onCatalogLoadMoreRequested,
        catalogTotalCount: widget.catalogTotalCount,
        catalogHasMore: widget.catalogHasMore,
        catalogLoadingMore: widget.catalogLoadingMore,
        catalogLoadMoreFailed: widget.catalogLoadMoreFailed,
        mostClickedNovels: widget.mostClickedNovels,
        recentSearches: _recentSearches,
        onSearchCommitted: _rememberSearch,
        onOpenNovel: _openNovel,
        onOpenRankings: _openRankings,
      ),
      LibraryScreen(
        novels: widget.novels,
        continuedReads: widget.continuedReads,
        protectedDownloads: widget.protectedDownloads,
        bookmarks: widget.bookmarks,
        remoteFavorites: widget.remoteFavorites,
        onOpenNovel: _openNovel,
        onOpenPosition: (novel, position) =>
            _openReader(novel, null, requestedPosition: position),
      ),
      SettingsScreen(
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
        storageSummary: widget.storageSummary,
        cacheLimitBytes: widget.cacheLimitBytes,
        onClearSearchHistory: () {
          setState(_recentSearches.clear);
          _notifyRecentSearchesChanged();
          _showFixtureAction('已清除本机搜索历史');
        },
        onLoginRequested:
            widget.onLoginRequested ??
            () => _showFixtureAction('尚未接入 Novelia 托管登录'),
        onReleasesRequested:
            widget.onReleasesRequested ??
            () => _showFixtureAction('版本页将由平台链接打开'),
      ),
    ];
    final useRail = MediaQuery.sizeOf(context).width >= 840;
    final content = IndexedStack(index: _destination, children: pages);

    return Scaffold(
      key: const ValueKey('novelia-shell'),
      body: useRail
          ? Row(
              children: [
                SafeArea(
                  child: NavigationRail(
                    key: const ValueKey('shell-navigation-rail'),
                    selectedIndex: _destination,
                    onDestinationSelected: _selectDestination,
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.library_books_outlined),
                        selectedIcon: Icon(Icons.library_books),
                        label: Text('书架'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            )
          : content,
      bottomNavigationBar: useRail
          ? null
          : NavigationBar(
              key: const ValueKey('shell-navigation-bar'),
              selectedIndex: _destination,
              onDestinationSelected: _selectDestination,
              destinations: const [
                NavigationDestination(
                  key: ValueKey('nav-discover'),
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: '发现',
                ),
                NavigationDestination(
                  key: ValueKey('nav-library'),
                  icon: Icon(Icons.library_books_outlined),
                  selectedIcon: Icon(Icons.library_books),
                  label: '书架',
                ),
                NavigationDestination(
                  key: ValueKey('nav-settings'),
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
    );
  }
}
