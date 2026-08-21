import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/account/account_models.dart';
import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../discover/catalog_models.dart';
import '../discover/catalog_search_results_screen.dart';
import '../discover/discover_screen.dart';
import '../discover/rankings_screen.dart';
import '../account/account_screen.dart';
import '../account/remote_novel_list_screen.dart';
import '../novel_details/novel_details_loader_screen.dart';
import '../novel_details/novel_details_screen.dart';
import 'download_management_screen.dart';
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

typedef FavoriteToFolderRequested =
    FutureOr<void> Function(CatalogNovel catalogNovel, String folderId);

typedef FavoriteFromFolderRemoveRequested =
    FutureOr<void> Function(CatalogNovel catalogNovel, String folderId);

typedef FavoriteFolderCreateRequested =
    Future<LibraryFavoriteFolder> Function(String title);

typedef NovelOriginalRequested =
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
    this.onFavoriteToFolderRequested,
    this.onFavoriteFromFolderRemoveRequested,
    this.onFavoriteFolderCreateRequested,
    this.onDownloadRequested,
    this.onDownloadManagementRequested,
    this.downloadManagementSnapshotLoader,
    this.onOpenOriginalRequested,
    this.onLoginRequested,
    this.accountSession = const AccountSessionSnapshot.signedOut(),
    this.onAccountLogin,
    this.onAccountLogout,
    this.onHostedAccountHelp,
    this.onReleasesRequested,
    this.continuedReads = const [],
    this.protectedDownloads = const [],
    this.bookmarks = const [],
    this.remoteFavorites = const RemoteFavoritesViewModel.unavailable(),
    this.favoriteFolderLoader,
    this.readingHistoryLoader,
    this.storageSummary = const OfflineStorageSummary(
      cacheBytes: 0,
      offlineDownloadBytes: 0,
      cacheChapterCount: 0,
      offlineDownloadChapterCount: 0,
      perNovel: [],
    ),
    this.cacheLimitBytes,
    this.onCacheLimitChanged,
    this.onClearReadingCache,
    this.initialCatalogCriteria = const CatalogCriteria(),
    this.onCatalogCriteriaRequested,
    this.onCatalogSearchRequested,
    this.onCatalogLoadMoreRequested,
    this.catalogTotalCount,
    this.catalogHasMore = false,
    this.catalogLoading = false,
    this.catalogLoadingMore = false,
    this.catalogLoadMoreFailed = false,
    this.rankingsLoader,
    this.mostClickedNovels = const [],
    this.recentlyUpdatedNovels = const [],
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
  final FavoriteToFolderRequested? onFavoriteToFolderRequested;
  final FavoriteFromFolderRemoveRequested? onFavoriteFromFolderRemoveRequested;
  final FavoriteFolderCreateRequested? onFavoriteFolderCreateRequested;
  final NovelDownloadRequested? onDownloadRequested;
  final DownloadManagementHandler? onDownloadManagementRequested;
  final DownloadManagementSnapshotLoader? downloadManagementSnapshotLoader;
  final NovelOriginalRequested? onOpenOriginalRequested;
  final VoidCallback? onLoginRequested;
  final AccountSessionSnapshot accountSession;
  final AccountLogin? onAccountLogin;
  final Future<void> Function()? onAccountLogout;
  final VoidCallback? onHostedAccountHelp;
  final VoidCallback? onReleasesRequested;
  final List<LibraryContinuedRead> continuedReads;
  final List<LibraryProtectedDownload> protectedDownloads;
  final List<LibraryBookmarkItem> bookmarks;
  final RemoteFavoritesViewModel remoteFavorites;
  final FavoriteFolderPageLoader? favoriteFolderLoader;
  final RemoteNovelPageLoader? readingHistoryLoader;
  final OfflineStorageSummary storageSummary;
  final int? cacheLimitBytes;
  final ValueChanged<int>? onCacheLimitChanged;
  final FutureOr<int> Function()? onClearReadingCache;
  final CatalogCriteria initialCatalogCriteria;
  final CatalogCriteriaRequested? onCatalogCriteriaRequested;

  /// Legacy search-only boundary retained while composition roots migrate to
  /// [onCatalogCriteriaRequested].
  final FutureOr<void> Function(String query)? onCatalogSearchRequested;
  final FutureOr<void> Function()? onCatalogLoadMoreRequested;
  final int? catalogTotalCount;
  final bool catalogHasMore;
  final bool catalogLoading;
  final bool catalogLoadingMore;
  final bool catalogLoadMoreFailed;
  final RankingsLoader? rankingsLoader;
  final List<CatalogNovel> mostClickedNovels;
  final List<CatalogNovel> recentlyUpdatedNovels;
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
  late int _destination = widget.initialDestination.clamp(0, 3);
  late final List<String> _recentSearches = List.of(
    widget.initialRecentSearches.take(8),
  );
  late CatalogCriteria _catalogCriteria = widget.initialCatalogCriteria;
  var _restoringInitialReader = false;
  String? _lastFavoriteFolderId;

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
    if (_destination != 1 || _catalogCriteria != criteria) {
      setState(() {
        _destination = 1;
        _catalogCriteria = criteria;
      });
      widget.onDestinationChanged?.call(1);
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    unawaited(_requestCatalogCriteria(criteria).catchError((_) {}));
  }

  void _openTag(String tag) {
    _openRemoteCatalogCriteria(CatalogCriteria(exactTag: tag));
  }

  void _showFixtureAction(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _ensureSignedIn() async {
    if (widget.accountSession.isSignedIn) return true;
    if (widget.accountSession.status == AccountSessionStatus.restoring) {
      _showFixtureAction('正在检查账号状态');
      return false;
    }
    if (widget.accountSession.hasStoredAccount) {
      widget.onLoginRequested?.call();
      if (!mounted) return false;
      if (widget.accountSession.isSignedIn) return true;
      _showFixtureAction('账号服务暂不可用，请到设置中重试或退出后重新登录');
      return false;
    }
    final login = widget.onAccountLogin;
    if (login == null) {
      widget.onLoginRequested?.call();
      return false;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AccountScreen(
          onLogin: login,
          onHostedAccountHelp: widget.onHostedAccountHelp,
        ),
        settings: const RouteSettings(name: '/account/login'),
      ),
    );
    return mounted && widget.accountSession.isSignedIn;
  }

  Future<bool> _requestFavorite(CatalogNovel novel) async {
    if (widget.onFavoriteToFolderRequested == null &&
        widget.onFavoriteRequested != null) {
      widget.onFavoriteRequested!(novel);
      return true;
    }
    if (!widget.accountSession.isSignedIn) {
      final signedIn = await _ensureSignedIn();
      if (!mounted) return false;
      if (signedIn) {
        _showFixtureAction('登录成功，请再次点击收藏');
      }
      return false;
    }
    final callback = widget.onFavoriteToFolderRequested;
    if (callback == null) {
      widget.onFavoriteRequested?.call(novel);
      return widget.onFavoriteRequested != null;
    }
    if (widget.remoteFavorites.status == RemoteFavoritesStatus.unavailable) {
      _showFixtureAction('收藏夹暂不可用，请稍后重试');
      return false;
    }
    final folders = widget.remoteFavorites.folders;
    try {
      if (folders.isEmpty) {
        final created = await _createFavoriteFolder();
        if (created == null || !mounted) return false;
        await callback(novel, created.id);
        _lastFavoriteFolderId = created.id;
      } else if (folders.length == 1) {
        await callback(novel, folders.single.id);
        _lastFavoriteFolderId = folders.single.id;
      } else {
        final folderId = await _chooseFavoriteFolder(folders);
        if (folderId == null || !mounted) return false;
        if (folderId == _createFolderChoice) {
          final created = await _createFavoriteFolder();
          if (created == null || !mounted) return false;
          await callback(novel, created.id);
          _lastFavoriteFolderId = created.id;
        } else {
          await callback(novel, folderId);
          _lastFavoriteFolderId = folderId;
        }
      }
      if (mounted) _showFixtureAction('已加入收藏夹');
      return true;
    } on Object {
      if (mounted) _showFixtureAction('收藏失败，请检查网络后重试');
      return false;
    }
  }

  static const _createFolderChoice = '__create_favorite_folder__';

  Future<String?> _chooseFavoriteFolder(
    List<LibraryFavoriteFolder> folders,
  ) async {
    var selected = folders.any((folder) => folder.id == _lastFavoriteFolderId)
        ? _lastFavoriteFolderId!
        : folders.first.id;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('收藏到…'),
          content: SizedBox(
            width: 360,
            child: RadioGroup<String>(
              groupValue: selected,
              onChanged: (value) {
                if (value != null) setDialogState(() => selected = value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final folder in folders)
                    RadioListTile<String>(
                      key: ValueKey('favorite-folder-choice-${folder.id}'),
                      value: folder.id,
                      title: Text(folder.title),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (widget.onFavoriteFolderCreateRequested != null)
              TextButton.icon(
                key: const ValueKey('create-favorite-folder-button'),
                onPressed: () => Navigator.of(context).pop(_createFolderChoice),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建收藏夹'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-favorite-folder'),
              onPressed: () => Navigator.of(context).pop(selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  Future<LibraryFavoriteFolder?> _createFavoriteFolder() async {
    final callback = widget.onFavoriteFolderCreateRequested;
    if (callback == null) return null;
    final controller = TextEditingController();
    try {
      final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('新建收藏夹'),
          content: TextField(
            key: const ValueKey('favorite-folder-title-field'),
            controller: controller,
            autofocus: true,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) {
              final normalized = value.trim();
              if (normalized.isNotEmpty) {
                Navigator.of(context).pop(normalized);
              }
            },
            decoration: const InputDecoration(
              labelText: '收藏夹名称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-create-favorite-folder'),
              onPressed: () {
                final normalized = controller.text.trim();
                if (normalized.isNotEmpty) {
                  Navigator.of(context).pop(normalized);
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      );
      if (title == null || !mounted) return null;
      return await callback(title);
    } finally {
      controller.dispose();
    }
  }

  void _openFavoriteFolder(LibraryFavoriteFolder folder) {
    final loader = widget.favoriteFolderLoader;
    if (loader == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RemoteNovelListScreen(
          title: folder.title,
          loader: (page) => loader(folder.id, page),
          onOpenNovel: _openNovel,
          onTagSelected: _openTag,
          onRemoveNovel: widget.onFavoriteFromFolderRemoveRequested == null
              ? null
              : (novel) => widget.onFavoriteFromFolderRemoveRequested!(
                  novel,
                  folder.id,
                ),
        ),
        settings: RouteSettings(name: '/favorite/${folder.id}'),
      ),
    );
  }

  Future<void> _openReadingHistory() async {
    final loader = widget.readingHistoryLoader;
    if (loader == null) return;
    if (!widget.accountSession.isSignedIn) {
      final signedIn = await _ensureSignedIn();
      if (!mounted || !signedIn) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RemoteNovelListScreen(
          title: '阅读历史',
          loader: loader,
          onOpenNovel: _openNovel,
          onTagSelected: _openTag,
        ),
        settings: const RouteSettings(name: '/read-history'),
      ),
    );
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
            onFavorite:
                widget.onFavoriteRequested == null &&
                    widget.onFavoriteToFolderRequested == null &&
                    widget.onAccountLogin == null
                ? null
                : () => _requestFavorite(novel),
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
            onTagSelected: _openTag,
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
          onTagSelected: _openTag,
        ),
        settings: const RouteSettings(name: '/catalog/search'),
      ),
    );
  }

  Future<void> _openDownloadsManager() async {
    final handler = widget.onDownloadManagementRequested;
    if (handler == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DownloadManagementScreen(
          downloads: widget.protectedDownloads,
          onAction: handler,
          snapshotLoader: widget.downloadManagementSnapshotLoader,
          onOpenNovel: _openNovel,
        ),
        settings: const RouteSettings(name: '/library/downloads'),
      ),
    );
  }

  void _openRankings() {}

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
        mode: DiscoverScreenMode.discovery,
        novels: widget.recentlyUpdatedNovels.isEmpty
            ? widget.novels
            : widget.recentlyUpdatedNovels,
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
        mostClickedNovels: widget.mostClickedNovels,
        rankingsLoader: widget.rankingsLoader,
        onOpenNovel: _openNovel,
        onOpenRankings: _openRankings,
        onTagSelected: _openTag,
      ),
      DiscoverScreen(
        mode: DiscoverScreenMode.search,
        novels: widget.novels,
        catalogAvailability: widget.catalogAvailability,
        initialCriteria: _catalogCriteria,
        onCriteriaRequested: widget.onCatalogCriteriaRequested == null
            ? null
            : _requestCatalogCriteria,
        onSearchRequested: widget.onCatalogSearchRequested,
        onLoadMoreRequested: widget.onCatalogLoadMoreRequested,
        catalogTotalCount: widget.catalogTotalCount,
        catalogHasMore: widget.catalogHasMore,
        catalogLoading: widget.catalogLoading,
        catalogLoadingMore: widget.catalogLoadingMore,
        catalogLoadMoreFailed: widget.catalogLoadMoreFailed,
        recentSearches: _recentSearches,
        onSearchCommitted: _rememberSearch,
        rankingsLoader: widget.rankingsLoader,
        onOpenNovel: _openNovel,
        onOpenRankings: _openRankings,
        onTagSelected: _openTag,
      ),
      LibraryScreen(
        continuedReads: widget.continuedReads,
        protectedDownloads: widget.protectedDownloads,
        bookmarks: widget.bookmarks,
        remoteFavorites: widget.remoteFavorites,
        onFavoriteFolderRequested: widget.favoriteFolderLoader == null
            ? null
            : _openFavoriteFolder,
        onReadingHistoryRequested: widget.readingHistoryLoader == null
            ? null
            : _openReadingHistory,
        onOpenNovel: _openNovel,
        onOpenPosition: (novel, position) =>
            _openReader(novel, null, requestedPosition: position),
        onDownloadsManageRequested:
            widget.onDownloadManagementRequested == null ||
                widget.protectedDownloads.isEmpty
            ? null
            : _openDownloadsManager,
      ),
      SettingsScreen(
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
        storageSummary: widget.storageSummary,
        cacheLimitBytes: widget.cacheLimitBytes,
        onManageOfflineDownloads: widget.onDownloadManagementRequested == null
            ? null
            : _openDownloadsManager,
        onCacheLimitChanged: widget.onCacheLimitChanged,
        onClearReadingCache: widget.onClearReadingCache,
        onClearSearchHistory: () {
          setState(_recentSearches.clear);
          _notifyRecentSearchesChanged();
          _showFixtureAction('已清除本机搜索历史');
        },
        accountSession: widget.accountSession,
        onAccountLogin: widget.onAccountLogin,
        onAccountLogout: widget.onAccountLogout,
        onHostedAccountHelp: widget.onHostedAccountHelp,
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
                        icon: Icon(Icons.search),
                        selectedIcon: Icon(Icons.manage_search),
                        label: Text('搜索'),
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
                  key: ValueKey('nav-search'),
                  icon: Icon(Icons.search),
                  selectedIcon: Icon(Icons.manage_search),
                  label: '搜索',
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
