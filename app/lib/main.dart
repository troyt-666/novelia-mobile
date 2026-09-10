import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/account/account_session_controller.dart';
import 'core/account/account_models.dart';
import 'core/account/remote_history_sync.dart';
import 'core/account/secure_session_store.dart';
import 'core/database/local_state_repository.dart';
import 'core/database/sqlite_offline_repository.dart';
import 'core/model/reader_models.dart';
import 'core/offline/offline_models.dart';
import 'core/platform/app_update.dart';
import 'core/platform/app_update_installer.dart';
import 'core/platform/app_version.dart';
import 'core/platform/external_link_launcher.dart';
import 'features/discover/catalog_models.dart';
import 'features/discover/rankings_screen.dart';
import 'features/account/remote_novel_list_screen.dart';
import 'features/reader/reader_screen.dart';
import 'features/shell/download_management_screen.dart';
import 'features/shell/novelia_shell.dart';
import 'features/shell/shell_view_models.dart';
import 'features/shell/local_library_snapshot.dart';
import 'gateway/novelia/http_novelia_gateway.dart';
import 'gateway/novelia/http_novelia_wenku_gateway.dart';
import 'gateway/novelia/http_novelia_auth_gateway.dart';
import 'gateway/novelia/http_novelia_account_gateway.dart';
import 'gateway/novelia/novelia_account_gateway.dart';
import 'gateway/novelia/novelia_content_cache_adapter.dart';
import 'gateway/novelia/novelia_content_coordinator.dart';
import 'gateway/novelia/novelia_catalog_controller.dart';
import 'gateway/novelia/novelia_download_coordinator.dart';
import 'gateway/novelia/novelia_domain_adapter.dart';
import 'gateway/novelia/novelia_gateway.dart';
import 'gateway/novelia/novelia_wenku_gateway.dart';
import 'gateway/novelia/novelia_reader_window.dart';

const _defaultCacheLimitBytes = 256 * 1024 * 1024;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final appVersion = await const InstalledAppVersion().load();
    final repository = await SqliteOfflineRepository.openApplicationSupport();
    final authGateway = HttpNoveliaAuthGateway();
    final accountSessionController = AccountSessionController(
      gateway: authGateway,
      store: const MethodChannelAccountSessionStore(),
    );
    final gateway = HttpNoveliaGateway(
      accessTokenProvider: accountSessionController.accessToken,
    );
    final wenkuGateway = HttpNoveliaWenkuGateway();
    final accountGateway = HttpNoveliaAccountGateway(
      accessTokenProvider: accountSessionController.accessToken,
    );
    final contentCoordinator = LiveFirstNoveliaContentCoordinator(
      gateway: gateway,
      contentRepository: repository,
      canAccessRestrictedContent: () =>
          accountSessionController.snapshot.isSignedIn,
      onChapterCached: ({required novelId, required chapterId}) {
        final cacheLimit =
            repository.appSettings()?.cacheLimitBytes ??
            _defaultCacheLimitBytes;
        repository.evictCacheTo(
          maxBytes: cacheLimit,
          protectedChapters: {
            ChapterRef(novelId: novelId, chapterId: chapterId),
          },
        );
      },
    );
    final downloadCoordinator = AsyncNoveliaDownloadCoordinator(
      gateway: gateway,
      contentRepository: repository,
      offlineRepository: repository,
      canAccessRestrictedContent: () =>
          accountSessionController.snapshot.isSignedIn,
    );
    runApp(
      NoveliaReaderApp(
        appVersion: appVersion,
        repository: repository,
        accountSessionController: accountSessionController,
        accountGateway: accountGateway,
        contentCoordinator: contentCoordinator,
        wenkuGateway: wenkuGateway,
        downloadCoordinator: downloadCoordinator,
        externalLinkLauncher: const MethodChannelExternalLinkLauncher(),
        updateChecker: Platform.operatingSystem == 'ohos'
            ? null
            : GitHubAppUpdateChecker(platform: AppUpdatePlatform.current()),
        updateInstaller: Platform.isAndroid
            ? AndroidAppUpdateInstaller()
            : Platform.isMacOS
            ? const MacOsSparkleUpdateInstaller()
            : null,
        closeRepositoryOnDispose: true,
        onRuntimeDispose: () {
          gateway.close();
          authGateway.close();
          accountGateway.close();
          wenkuGateway.close();
        },
      ),
    );
  } on Object {
    runApp(const _DatabaseUnavailableApp());
  }
}

class NoveliaReaderApp extends StatefulWidget {
  const NoveliaReaderApp({
    required this.repository,
    required this.contentCoordinator,
    this.appVersion = const AppVersion.unavailable(),
    this.wenkuGateway,
    this.downloadCoordinator,
    this.accountSessionController,
    this.accountGateway,
    this.externalLinkLauncher,
    this.updateChecker,
    this.updateInstaller,
    this.catalogQuery = const NoveliaCatalogQuery(),
    this.onRuntimeDispose,
    this.closeRepositoryOnDispose = false,
    super.key,
  });

  final SqliteOfflineRepository repository;
  final AppVersion appVersion;
  final NoveliaContentCoordinator contentCoordinator;
  final NoveliaWenkuGateway? wenkuGateway;
  final NoveliaDownloadCoordinator? downloadCoordinator;
  final AccountSessionController? accountSessionController;
  final NoveliaAccountGateway? accountGateway;
  final ExternalLinkLauncher? externalLinkLauncher;
  final AppUpdateChecker? updateChecker;
  final AppUpdateInstaller? updateInstaller;
  final NoveliaCatalogQuery catalogQuery;
  final VoidCallback? onRuntimeDispose;
  final bool closeRepositoryOnDispose;

  @override
  State<NoveliaReaderApp> createState() => _NoveliaReaderAppState();
}

class _NoveliaReaderAppState extends State<NoveliaReaderApp>
    with WidgetsBindingObserver {
  late LocalLibrarySnapshot _library;
  late ThemeMode _themeMode;
  late ReaderSettings _readerSettings;
  late int _cacheLimitBytes;
  late int _initialDestination;
  late List<String> _initialRecentSearches;
  late String? _initialReaderNovelId;
  late ReadingPosition? _initialReaderPosition;
  late final NoveliaCatalogController _feeds;
  List<CatalogNovel> get _catalogNovels => _feeds.catalog.novels;
  CatalogCriteria get _catalogCriteria => _feeds.criteria;
  final Set<String> _activeDownloadSyncs = <String>{};
  final Set<String> _pendingDownloadSyncs = <String>{};
  var _defaultRankingPageSize = 0;
  var _currentDestination = 0;
  var _remoteFavorites = const RemoteFavoritesViewModel.unavailable();
  var _favoriteFolderGeneration = 0;
  late final RemoteHistorySync _historySync;

  SqliteOfflineRepository get _repository => widget.repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _historySync = RemoteHistorySync(
      repository: _repository,
      sessionController: widget.accountSessionController,
      gateway: widget.accountGateway,
    );
    widget.accountSessionController?.addListener(_accountSessionChanged);
    if (widget.accountSessionController != null) {
      unawaited(widget.accountSessionController!.restore());
    }
    final settings = _repository.appSettings();
    _readerSettings = settings?.readerSettings ?? const ReaderSettings();
    _themeMode = _themeModeFromPreference(
      settings?.themePreference ?? ThemePreference.system,
    );
    _cacheLimitBytes = settings?.cacheLimitBytes ?? _defaultCacheLimitBytes;
    _initialRecentSearches = _repository.recentSearches();

    final route = _repository.lastRoute();
    _initialDestination = _destinationForRoute(route?.routeName);
    _currentDestination = _initialDestination;
    final restoreReader = route?.routeName == '/reader';
    _initialReaderNovelId = restoreReader ? route?.novelId : null;
    _initialReaderPosition = restoreReader ? route?.position : null;

    _repository.evictCacheTo(maxBytes: _cacheLimitBytes);
    _feeds = NoveliaCatalogController(
      contentCoordinator: widget.contentCoordinator,
      baseQuery: widget.catalogQuery,
      initialNovels: _restoreCachedCatalog(),
      canAccessRestrictedContent: () =>
          widget.accountSessionController?.snapshot.isSignedIn == true,
      onContentChanged: (novels) {
        if (novels.any((novel) => _library.novelIds.contains(novel.id))) {
          _refreshLibrary();
        }
      },
    );
    _library = _loadLibrarySnapshot();
    unawaited(_feeds.refreshCatalog());
    unawaited(_feeds.refreshRecentlyUpdated());
    unawaited(_feeds.refreshMostClicked());
    unawaited(_resumeDownloadIntents());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.accountSessionController?.removeListener(_accountSessionChanged);
    _feeds.dispose();
    _historySync.dispose();
    widget.onRuntimeDispose?.call();
    if (widget.closeRepositoryOnDispose) _repository.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_feeds.refreshCatalog());
    unawaited(_feeds.refreshRecentlyUpdated());
    unawaited(_feeds.refreshMostClicked());
    if (widget.downloadCoordinator != null) {
      unawaited(_resumeDownloadIntents());
    }
    if (widget.accountSessionController?.snapshot.status ==
        AccountSessionStatus.unavailable) {
      unawaited(widget.accountSessionController!.retry());
    } else if (widget.accountSessionController?.snapshot.isSignedIn == true) {
      unawaited(_refreshFavoriteFolders());
      unawaited(_historySync.flush());
    }
  }

  void _accountSessionChanged() {
    if (!mounted) return;
    final session = widget.accountSessionController?.snapshot;
    _historySync.updateSession(session);
    if (session?.isSignedIn == true) {
      unawaited(_refreshFavoriteFolders());
      unawaited(_historySync.flush());
    } else {
      _favoriteFolderGeneration += 1;
      _remoteFavorites = const RemoteFavoritesViewModel.unavailable();
    }
    if (_catalogCriteria.contentLevel != CatalogContentLevel.general) {
      unawaited(_feeds.refreshCatalog(criteria: _catalogCriteria));
    }
    _refreshLibrary();
  }

  Future<void> _refreshFavoriteFolders() async {
    final gateway = widget.accountGateway;
    if (gateway == null ||
        widget.accountSessionController?.snapshot.isSignedIn != true) {
      return;
    }
    final generation = ++_favoriteFolderGeneration;
    try {
      final folders = await gateway.listFavoriteFolders();
      if (!mounted || generation != _favoriteFolderGeneration) return;
      setState(() {
        _remoteFavorites = folders.isEmpty
            ? const RemoteFavoritesViewModel.empty()
            : RemoteFavoritesViewModel.available([
                for (final folder in folders)
                  LibraryFavoriteFolder(id: folder.id, title: folder.title),
              ]);
      });
    } on Object {
      if (!mounted || generation != _favoriteFolderGeneration) return;
      setState(
        () => _remoteFavorites = const RemoteFavoritesViewModel.unavailable(),
      );
    }
  }

  Future<LibraryFavoriteFolder> _createFavoriteFolder(String title) async {
    final gateway = widget.accountGateway;
    if (gateway == null) throw StateError('Account gateway is unavailable.');
    final folder = await gateway.createFavoriteFolder(title);
    await _refreshFavoriteFolders();
    return LibraryFavoriteFolder(id: folder.id, title: folder.title);
  }

  Future<void> _favoriteNovel(CatalogNovel novel, String folderId) async {
    final gateway = widget.accountGateway;
    final key = _serviceNovelKey(novel.id);
    if (gateway == null || key == null) {
      throw StateError('Novel cannot be mapped to a service identity.');
    }
    await gateway.favoriteWebNovel(
      folderId: folderId,
      providerId: key.$1,
      novelId: key.$2,
    );
  }

  Future<void> _unfavoriteNovel(CatalogNovel novel, String folderId) async {
    final gateway = widget.accountGateway;
    final key = _serviceNovelKey(novel.id);
    if (gateway == null || key == null) {
      throw StateError('Novel cannot be mapped to a service identity.');
    }
    await gateway.unfavoriteWebNovel(
      folderId: folderId,
      providerId: key.$1,
      novelId: key.$2,
    );
  }

  Future<RemoteNovelPageView> _loadFavoriteFolderPage(
    String folderId,
    int pageNumber,
  ) async {
    final gateway = widget.accountGateway;
    if (gateway == null) throw StateError('Account gateway is unavailable.');
    final page = await gateway.listFavoriteWebNovels(
      folderId: folderId,
      page: pageNumber - 1,
    );
    return _mapAccountNovelPage(page, pageNumber);
  }

  Future<RemoteNovelPageView> _loadReadingHistoryPage(int pageNumber) async {
    final gateway = widget.accountGateway;
    if (gateway == null) throw StateError('Account gateway is unavailable.');
    final page = await gateway.listReadHistory(page: pageNumber - 1);
    return _mapAccountNovelPage(page, pageNumber);
  }

  RemoteNovelPageView _mapAccountNovelPage(
    NoveliaPage<NoveliaNovelOutline> page,
    int pageNumber,
  ) {
    const domainAdapter = NoveliaDomainAdapter();
    const cacheAdapter = NoveliaContentCacheAdapter();
    final fetchedAt = DateTime.now().toUtc();
    final allowRestricted =
        widget.accountSessionController?.snapshot.isSignedIn == true;
    final novels = <CatalogNovel>[];
    for (final outline in page.items) {
      try {
        final novel = domainAdapter.mapOutline(
          outline,
          allowRestricted: allowRestricted,
        );
        novels.add(novel);
        try {
          _repository.upsertNovelOutline(
            cacheAdapter.cacheOutline(novel, fetchedAt: fetchedAt),
          );
        } on Object {
          // A cache failure must not hide an otherwise valid account row.
        }
      } on NoveliaRestrictedContentException {
        // Phase 3 remains within the general-content boundary established by
        // the anonymous catalog even if an account contains older R18 rows.
      }
    }
    return RemoteNovelPageView(
      novels: novels,
      pageNumber: pageNumber,
      totalPages: page.pageCount,
    );
  }

  Future<void> _logoutAccount() async {
    _historySync.signedOut();
    await widget.accountSessionController?.logout();
  }

  static (String, String)? _serviceNovelKey(String stableId) {
    final separator = stableId.indexOf('/');
    if (separator <= 0 || separator == stableId.length - 1) return null;
    return (
      stableId.substring(0, separator),
      stableId.substring(separator + 1),
    );
  }

  List<CatalogNovel> _restoreCachedCatalog() {
    const adapter = NoveliaContentCacheAdapter();
    final novels = <CatalogNovel>[];
    for (final outline in _repository.listCachedNovels()) {
      try {
        novels.add(adapter.restoreOutline(outline));
      } on Object {
        // One corrupt or obsolete cache row must not hide the remaining shelf.
      }
    }
    novels.sort((a, b) {
      final aUpdated = a.updatedAt;
      final bUpdated = b.updatedAt;
      if (aUpdated == null && bUpdated == null) return a.id.compareTo(b.id);
      if (aUpdated == null) return 1;
      if (bUpdated == null) return -1;
      final order = bUpdated.compareTo(aUpdated);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return List.unmodifiable(novels);
  }

  Future<void> _refreshDiscoveryFeeds() => Future.wait([
    _feeds.refreshRecentlyUpdated(),
    _feeds.refreshMostClicked(),
  ]);

  Future<void> _loadMoreDiscovery(CatalogSort sort) =>
      sort == CatalogSort.mostClicked
      ? _feeds.refreshMostClicked(append: true)
      : _feeds.refreshRecentlyUpdated(append: true);

  Future<RankingPageView> _loadRankings(RankingsQuery query) async {
    final providerId = _rankingProviderId(query.source);
    final range = _rankingRange(query.period);
    final kakuyomu = providerId == 'kakuyomu';
    final result = await widget.contentCoordinator.loadRankings(
      kakuyomu
          ? NoveliaRankingQuery.kakuyomu(
              genre: query.genre ?? '综合',
              range: range,
              status: _rankingStatus(query.publicationState, kakuyomu: true),
            )
          : NoveliaRankingQuery.syosetu(
              type: query.genre == null ? '综合' : '流派',
              genre: query.genre,
              range: range,
              status: _rankingStatus(query.publicationState, kakuyomu: false),
              page: query.pageNumber,
            ),
    );
    final slice = result.data;
    if (slice == null) {
      throw result.failure ?? StateError('Rankings are unavailable.');
    }
    if (query.pageNumber == 1 && slice.novels.isNotEmpty) {
      _defaultRankingPageSize = slice.novels.length;
    }
    final pageSize = _defaultRankingPageSize > 0
        ? _defaultRankingPageSize
        : slice.novels.length;
    final sourceLabel = kakuyomu ? 'Kakuyomu' : 'Syosetu';
    final genreLabel = query.genre ?? (kakuyomu ? '综合' : '综合');
    return RankingPageView(
      novels: slice.novels,
      pageNumber: kakuyomu ? query.pageNumber : slice.pageIndex + 1,
      totalPages: kakuyomu
          ? 1
          : slice.totalPages == 0
          ? 1
          : slice.totalPages,
      description:
          '$sourceLabel · $genreLabel · ${query.period.label} · 服务原生排序',
      firstRank: pageSize == 0 ? 1 : ((query.pageNumber - 1) * pageSize) + 1,
    );
  }

  static String _rankingProviderId(String? source) {
    final normalized = (source ?? 'syosetu').toLowerCase();
    return switch (normalized) {
      'syosetu' => 'syosetu',
      'kakuyomu' => 'kakuyomu',
      _ => throw ArgumentError.value(
        source,
        'source',
        'Unsupported ranking provider.',
      ),
    };
  }

  static String _rankingRange(RankingPeriod period) {
    return switch (period) {
      RankingPeriod.overall => '总计',
      RankingPeriod.yearly => '每年',
      RankingPeriod.monthly => '每月',
      RankingPeriod.weekly => '每周',
      RankingPeriod.daily => '每日',
    };
  }

  static String _rankingStatus(
    NovelPublicationState? state, {
    required bool kakuyomu,
  }) {
    // Kakuyomu's `status` parameter describes work length, not publication
    // completion. The UI therefore omits its publication-state filter.
    if (kakuyomu) return '全部';
    return switch (state) {
      null || NovelPublicationState.unknown => '全部',
      NovelPublicationState.shortStory => '短篇',
      NovelPublicationState.ongoing => '连载',
      NovelPublicationState.completed => '完结',
    };
  }

  Future<CatalogNovel> _loadNovelDetails(CatalogNovel outline) async {
    final result = await widget.contentCoordinator.loadDetails(outline);
    final loaded = result.data;
    if (loaded == null) {
      throw result.failure ?? StateError('Novel details are unavailable.');
    }
    if (mounted) {
      // Do not rebuild the app-level Navigator while its detail loader is
      // completing. The hydrated aggregate is picked up on the next ordinary
      // state change, while the active route receives [loaded] directly.
      _feeds.rememberDetails(loaded);
    }
    return loaded;
  }

  Future<ReaderLaunchData> _loadReaderWindow(
    CatalogNovel novel,
    NovelChapter? selectedChapter,
    ReadingPosition? requestedPosition,
  ) async {
    final hydrated = novel.hasChapterCatalog
        ? novel
        : await _loadNovelDetails(novel);
    final effectivePosition =
        requestedPosition ??
        (selectedChapter == null
            ? _repository.readingProgressFor(novel.id)?.position
            : null);
    final data =
        await NoveliaReaderWindowFactory(
          contentCoordinator: widget.contentCoordinator,
        ).create(
          novel: hydrated,
          selectedChapter: selectedChapter,
          requestedPosition: effectivePosition,
          translationSource: _readerSettings.translationSource,
        );
    _repository.evictCacheTo(
      maxBytes: _cacheLimitBytes,
      protectedChapters: {
        for (final chapter in data.novel.chapters)
          ChapterRef(novelId: data.novel.id, chapterId: chapter.id),
      },
    );
    return data;
  }

  Future<NovelCommentPage> _loadCommentPage(
    CatalogNovel novel,
    int pageNumber,
  ) async {
    final result = await widget.contentCoordinator.loadComments(
      novel,
      pageNumber: pageNumber,
    );
    final slice = result.data;
    if (slice == null) {
      throw result.failure ?? StateError('Comments are unavailable.');
    }
    return NovelCommentPage(
      pageNumber: slice.pageNumber,
      totalPages: slice.totalPages,
      totalComments: null,
      comments: slice.comments,
    );
  }

  Future<void> _resumeDownloadIntents() async {
    final coordinator = widget.downloadCoordinator;
    if (coordinator == null) return;
    for (final intent in _repository.listIntents()) {
      if (!intent.enabled) continue;
      await _synchronizeIntent(intent.id, retryFailures: true);
    }
  }

  Future<NoveliaDownloadRun?> _synchronizeIntent(
    String intentId, {
    bool retryFailures = false,
  }) async {
    final coordinator = widget.downloadCoordinator;
    if (coordinator == null) return null;
    if (!_activeDownloadSyncs.add(intentId)) {
      _pendingDownloadSyncs.add(intentId);
      return null;
    }
    _pendingDownloadSyncs.remove(intentId);
    NoveliaDownloadRun? run;
    try {
      if (retryFailures) {
        final now = DateTime.now().toUtc();
        _repository.requeueInterruptedTasks(intentId: intentId, now: now);
      }
      run = await coordinator.synchronizeIntent(intentId);
    } on Object {
      run = null;
    } finally {
      _activeDownloadSyncs.remove(intentId);
      _refreshLibrary();
    }
    if (mounted && _pendingDownloadSyncs.remove(intentId)) {
      unawaited(_synchronizeIntent(intentId, retryFailures: true));
    }
    return run;
  }

  void _setThemeMode(ThemeMode mode) {
    if (mode != _themeMode) setState(() => _themeMode = mode);
    _saveSettings();
  }

  void _setReaderSettings(ReaderSettings settings) {
    _readerSettings = settings;
    _saveSettings();
  }

  void _saveSettings() {
    _repository.saveAppSettings(
      LocalAppSettings(
        readerSettings: _readerSettings,
        themePreference: _preferenceFromThemeMode(_themeMode),
        cacheLimitBytes: _cacheLimitBytes,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void _setCacheLimit(int bytes) {
    if (bytes == _cacheLimitBytes) return;
    _cacheLimitBytes = bytes;
    _saveSettings();
    _repository.evictCacheTo(maxBytes: bytes);
    _refreshLibrary();
  }

  Future<int> _clearReadingCache() async {
    final removed = _repository.evictCacheTo(maxBytes: 0);
    _refreshLibrary();
    return removed.length;
  }

  void _saveTopLevelRoute(int destination) {
    _currentDestination = destination;
    if (destination == 2) unawaited(_refreshFavoriteFolders());
    _repository.saveLastRoute(
      LastRouteState(
        routeName: _routeForDestination(destination),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    _refreshLibrary();
  }

  void _saveReaderPosition(
    ReaderNovel novel,
    ReadingPosition position, {
    bool syncRemoteHistory = true,
  }) {
    final now = DateTime.now().toUtc();
    _saveProgressOnly(novel, position, now);
    if (syncRemoteHistory) _historySync.record(novel, position, now);
    _repository.touchChapterCopies(novel.id, position.chapterId, now);
    _repository.saveLastRoute(
      LastRouteState(
        routeName: '/reader',
        novelId: novel.id,
        position: position,
        updatedAt: now,
      ),
    );
  }

  void _saveProgressOnly(
    ReaderNovel novel,
    ReadingPosition position, [
    DateTime? savedAt,
  ]) {
    final now = savedAt ?? DateTime.now().toUtc();
    _repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: novel.id,
        position: position,
        updatedAt: now,
      ),
    );
  }

  void _saveBookmark(
    ReaderNovel novel,
    ReadingPosition position,
    bool bookmarked,
  ) {
    final id = _bookmarkId(novel.id, position);
    if (!bookmarked) {
      _repository.removeBookmark(id);
      return;
    }
    _repository.saveBookmark(
      LocalBookmark(
        id: id,
        novelId: novel.id,
        position: position,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _downloadNovel(CatalogNovel novel) async {
    final source = _readerSettings.translationSource;
    NovelDownloadIntent? intent;
    for (final candidate in _repository.listIntents()) {
      if (candidate is NovelDownloadIntent &&
          candidate.novelId == novel.id &&
          candidate.translationSource == source) {
        intent = candidate;
        break;
      }
    }
    final now = DateTime.now().toUtc();
    if (intent == null) {
      intent = NovelDownloadIntent(
        id: [
          'novel',
          novel.id,
          source.name,
          '${now.microsecondsSinceEpoch}',
        ].map(Uri.encodeComponent).join('::'),
        novelId: novel.id,
        translationSource: source,
        createdAt: now,
      );
      _repository.saveIntent(intent);
    } else if (!intent.enabled) {
      _repository.resumeIntent(intent.id, now);
      intent = intent.withEnabled(true);
    }
    // Registering a protected download is the user action. Hydrating the TOC
    // and fetching every chapter can take minutes, so chapter-level failures
    // belong in Download Management instead of turning a valid creation into
    // a misleading "creation failed" toast.
    unawaited(_synchronizeIntent(intent.id, retryFailures: true));
    _refreshLibrary();
  }

  Future<LibraryProtectedDownload?> _manageDownload(
    DownloadManagementAction action,
    LibraryProtectedDownload download,
  ) async {
    if (download.intentIds.isEmpty) {
      throw StateError('The protected download has no owning intent.');
    }
    final now = DateTime.now().toUtc();
    final existingIntentIds = [
      for (final intentId in download.intentIds)
        if (_repository.intentById(intentId) != null) intentId,
    ];
    if (existingIntentIds.isEmpty) {
      throw StateError('The protected download intent no longer exists.');
    }

    switch (action) {
      case DownloadManagementAction.pause:
        for (final intentId in existingIntentIds) {
          final intent = _repository.intentById(intentId)!;
          if (intent.enabled) _repository.pauseIntent(intentId, now);
        }
        break;
      case DownloadManagementAction.resume:
        for (final intentId in existingIntentIds) {
          final intent = _repository.intentById(intentId)!;
          if (!intent.enabled) _repository.resumeIntent(intentId, now);
          await _synchronizeIntent(intentId, retryFailures: true);
        }
        break;
      case DownloadManagementAction.retry:
        for (final intentId in existingIntentIds) {
          final intent = _repository.intentById(intentId)!;
          if (!intent.enabled) _repository.resumeIntent(intentId, now);
          await _synchronizeIntent(intentId, retryFailures: true);
        }
        break;
      case DownloadManagementAction.remove:
        for (final intentId in existingIntentIds) {
          _repository.removeIntent(intentId, now);
        }
        break;
    }

    _refreshLibrary();
    if (action == DownloadManagementAction.remove) return null;
    final updated = _library.downloads;
    return updated
        .where((candidate) => candidate.groupKey == download.groupKey)
        .firstOrNull;
  }

  LocalLibrarySnapshot _loadLibrarySnapshot() => LocalLibrarySnapshot.load(
    _repository,
    knownNovels: _catalogNovels,
    allowRestricted:
        widget.accountSessionController?.snapshot.isSignedIn == true,
  );

  void _refreshLibrary() {
    if (!mounted) return;
    setState(() => _library = _loadLibrarySnapshot());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JFZ Reader',
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'jfzreader-app',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: _themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: _feeds.catalog,
        builder: (context, child) =>
            _initialReaderNovelId != null &&
                _feeds.catalog.loading &&
                !_catalogNovels.any(
                  (novel) => novel.id == _initialReaderNovelId,
                )
            ? Scaffold(
                key: const ValueKey('reader-restore-placeholder'),
                body: Center(
                  child: Semantics(
                    label: '正在恢复阅读位置',
                    child: SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
              )
            : child!,
        child: NoveliaShell(
          catalogController: _feeds,
          wenkuGateway: widget.wenkuGateway,
          appVersion: widget.appVersion,
          novels: _catalogNovels,
          catalogAvailability: _feeds.searchAvailability,
          discoveryAvailability: _feeds.discoveryAvailability,
          continuedReads: _library.continuedReads,
          protectedDownloads: _library.downloads,
          bookmarks: _library.bookmarks,
          remoteFavorites: _remoteFavorites,
          favoriteFolderLoader: widget.accountGateway == null
              ? null
              : _loadFavoriteFolderPage,
          readingHistoryLoader: widget.accountGateway == null
              ? null
              : _loadReadingHistoryPage,
          accountSession:
              widget.accountSessionController?.snapshot ??
              const AccountSessionSnapshot.signedOut(),
          onAccountLogin: widget.accountSessionController == null
              ? null
              : ({required username, required password}) => widget
                    .accountSessionController!
                    .login(username: username, password: password),
          onAccountLogout: widget.accountSessionController == null
              ? null
              : _logoutAccount,
          onLoginRequested: widget.accountSessionController?.retry,
          onHostedAccountHelp: widget.externalLinkLauncher == null
              ? null
              : () => widget.externalLinkLauncher!.open(
                  Uri.parse('https://auth.novelia.cc/?app=n'),
                ),
          onReleasesRequested: widget.externalLinkLauncher == null
              ? null
              : () => widget.externalLinkLauncher!.open(
                  Uri.parse(defaultReleasesUri),
                ),
          onCheckForUpdate: widget.updateChecker == null
              ? null
              : () => widget.updateChecker!.check(widget.appVersion),
          updateInstaller: widget.updateInstaller,
          onOpenUpdateLink: widget.externalLinkLauncher?.open,
          onFavoriteToFolderRequested: widget.accountGateway == null
              ? null
              : _favoriteNovel,
          onFavoriteFromFolderRemoveRequested: widget.accountGateway == null
              ? null
              : _unfavoriteNovel,
          onFavoriteFolderCreateRequested: widget.accountGateway == null
              ? null
              : _createFavoriteFolder,
          storageSummary: _library.storageSummary,
          cacheLimitBytes: _cacheLimitBytes,
          onCacheLimitChanged: _setCacheLimit,
          onClearReadingCache: _clearReadingCache,
          initialCatalogCriteria: _catalogCriteria,
          onCatalogCriteriaRequested: (criteria) =>
              _feeds.refreshCatalog(criteria: criteria),
          onCatalogLoadMoreRequested: () => _feeds.refreshCatalog(append: true),
          onDiscoveryRefreshRequested: _refreshDiscoveryFeeds,
          onDiscoveryLoadMoreRequested: _loadMoreDiscovery,
          catalogHasMore: _feeds.catalog.hasMore,
          catalogLoading: _feeds.catalog.loading,
          catalogLoadingMore: _feeds.catalog.loadingMore,
          catalogLoadMoreFailed: _feeds.catalog.loadMoreFailed,
          recentlyUpdatedHasMore: _feeds.recentlyUpdated.hasMore,
          recentlyUpdatedLoadingMore: _feeds.recentlyUpdated.loadingMore,
          recentlyUpdatedLoadMoreFailed: _feeds.recentlyUpdated.loadMoreFailed,
          mostClickedHasMore: _feeds.mostClicked.hasMore,
          mostClickedLoadingMore: _feeds.mostClicked.loadingMore,
          mostClickedLoadMoreFailed: _feeds.mostClicked.loadMoreFailed,
          mostClickedNovels: _feeds.mostClicked.novels,
          recentlyUpdatedNovels: _feeds.recentlyUpdated.novels,
          rankingsLoader: _loadRankings,
          novelDetailsLoader: _loadNovelDetails,
          readerLaunchLoader: _loadReaderWindow,
          commentPageLoader: _loadCommentPage,
          onOpenOriginalRequested: widget.externalLinkLauncher == null
              ? null
              : (novel) {
                  final uri = novel.originalUrl;
                  if (uri == null) {
                    throw StateError('The novel has no original-site URL.');
                  }
                  return widget.externalLinkLauncher!.open(uri);
                },
          themeMode: _themeMode,
          initialDestination: _initialDestination,
          initialRecentSearches: _initialRecentSearches,
          initialReaderNovelId: _initialReaderNovelId,
          initialReaderPosition: _initialReaderPosition,
          onThemeModeChanged: _setThemeMode,
          onDestinationChanged: _saveTopLevelRoute,
          onRecentSearchesChanged: _repository.saveRecentSearches,
          onReaderOpened: (_, data) {
            _initialReaderNovelId = null;
            final readerNovel = data.novel;
            final position = data.initialPosition;
            if (position != null) {
              _saveReaderPosition(
                readerNovel,
                position,
                syncRemoteHistory: false,
              );
            }
          },
          onReaderClosed: () {
            _initialReaderNovelId = null;
            _saveTopLevelRoute(_currentDestination);
          },
          onDownloadRequested: widget.downloadCoordinator == null
              ? null
              : _downloadNovel,
          onDownloadManagementRequested: _manageDownload,
          downloadManagementSnapshotLoader: () {
            // Download Management explicitly requests current task progress.
            _library = _loadLibrarySnapshot();
            return _library.downloads;
          },
          readerBuilder: (context, data) {
            final novel = data.novel;
            // The shell has already resolved explicit chapter selection, saved
            // progress, and the first-readable-block fallback. Reconsulting the
            // repository here can override an explicit chapter tap with an older
            // saved position from a different chapter.
            final initialPosition = data.initialPosition;
            final savedBookmarks = _repository.listBookmarks(novelId: novel.id);
            final bookmarkedBlocks = savedBookmarks
                .map((bookmark) => bookmark.position.blockId)
                .toSet();
            return ReaderScreen(
              novel: novel,
              initialPosition: initialPosition,
              startAtChapterTitle: data.startAtChapterTitle,
              initialBookmarkedBlockIds: bookmarkedBlocks,
              initialBookmarks: savedBookmarks
                  .map((bookmark) => bookmark.position)
                  .toList(growable: false),
              initialSettings: _readerSettings,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
              onSettingsChanged: _setReaderSettings,
              onPositionChanged: (position) =>
                  _saveReaderPosition(novel, position),
              onExitPosition: (position) => _saveProgressOnly(novel, position),
              onBookmarkChanged: (position, bookmarked) =>
                  _saveBookmark(novel, position, bookmarked),
              chapterDataSource: data.dataSource,
            );
          },
        ),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: brightness == Brightness.light
            ? const Color(0xFF397B62)
            : const Color(0xFF78B99A),
        brightness: brightness,
      ),
      useMaterial3: true,
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans CJK SC',
        'Hiragino Sans',
      ],
    );
  }

  static int _destinationForRoute(String? routeName) => switch (routeName) {
    '/search' => 1,
    '/library' => 2,
    '/settings' => 3,
    _ => 0,
  };

  static String _routeForDestination(int destination) => switch (destination) {
    1 => '/search',
    2 => '/library',
    3 => '/settings',
    _ => '/discover',
  };

  static ThemeMode _themeModeFromPreference(ThemePreference preference) {
    return switch (preference) {
      ThemePreference.system => ThemeMode.system,
      ThemePreference.light => ThemeMode.light,
      ThemePreference.dark => ThemeMode.dark,
    };
  }

  static ThemePreference _preferenceFromThemeMode(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => ThemePreference.system,
      ThemeMode.light => ThemePreference.light,
      ThemeMode.dark => ThemePreference.dark,
    };
  }

  static String _bookmarkId(String novelId, ReadingPosition position) {
    return [
      novelId,
      position.chapterId,
      position.blockId,
    ].map(Uri.encodeComponent).join('::');
  }
}

class _DatabaseUnavailableApp extends StatelessWidget {
  const _DatabaseUnavailableApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.storage_rounded,
                    size: 44,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '无法打开本地阅读数据',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '应用没有创建新的数据库覆盖原数据。请重新启动；如果问题持续，请保留应用数据并导出诊断信息。',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
