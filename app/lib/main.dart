import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/account/account_session_controller.dart';
import 'core/account/account_models.dart';
import 'core/account/account_sync_models.dart';
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
import 'fixtures/catalog_fixture.dart';
import 'gateway/novelia/http_novelia_gateway.dart';
import 'gateway/novelia/http_novelia_wenku_gateway.dart';
import 'gateway/novelia/http_novelia_auth_gateway.dart';
import 'gateway/novelia/http_novelia_account_gateway.dart';
import 'gateway/novelia/novelia_account_gateway.dart';
import 'gateway/novelia/novelia_content_cache_adapter.dart';
import 'gateway/novelia/novelia_content_coordinator.dart';
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
        updateChecker: GitHubAppUpdateChecker(
          platform: AppUpdatePlatform.current(),
        ),
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
    this.appVersion = const AppVersion.unavailable(),
    this.contentCoordinator,
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
  final NoveliaContentCoordinator? contentCoordinator;
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
  late ThemeMode _themeMode;
  late ReaderSettings _readerSettings;
  late bool _notifyNewChapters;
  late int _cacheLimitBytes;
  late int _initialDestination;
  late List<String> _initialRecentSearches;
  late String? _initialReaderNovelId;
  late ReadingPosition? _initialReaderPosition;
  late List<CatalogNovel> _catalogNovels;
  late List<CatalogNovel> _recentlyUpdatedNovels;
  late CatalogAvailability _catalogAvailability;
  late CatalogAvailability _recentlyUpdatedAvailability;
  late CatalogAvailability _mostClickedAvailability;
  final Set<String> _activeDownloadSyncs = <String>{};
  final Set<String> _pendingDownloadSyncs = <String>{};
  var _catalogLoadGeneration = 0;
  var _catalogPageIndex = -1;
  var _catalogTotalPages = 0;
  var _catalogCriteria = const CatalogCriteria();
  var _catalogLoading = false;
  var _catalogLoadingMore = false;
  var _catalogLoadMoreFailed = false;
  var _mostClickedNovels = const <CatalogNovel>[];
  var _mostClickedGeneration = 0;
  var _recentlyUpdatedGeneration = 0;
  var _mostClickedPageIndex = -1;
  var _mostClickedTotalPages = 0;
  var _mostClickedLoadingMore = false;
  var _mostClickedLoadMoreFailed = false;
  var _recentlyUpdatedPageIndex = -1;
  var _recentlyUpdatedTotalPages = 0;
  var _recentlyUpdatedLoadingMore = false;
  var _recentlyUpdatedLoadMoreFailed = false;
  var _defaultRankingPageSize = 0;
  var _currentDestination = 0;
  var _remoteFavorites = const RemoteFavoritesViewModel.unavailable();
  var _favoriteFolderGeneration = 0;
  var _historyFlushActive = false;
  var _historyOutboxOwnerInitialized = false;
  String? _historyOutboxOwner;
  final Map<String, String> _lastHistoryChapterByNovel = {};

  SqliteOfflineRepository get _repository => widget.repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.accountSessionController?.addListener(_accountSessionChanged);
    if (widget.accountSessionController != null) {
      unawaited(widget.accountSessionController!.restore());
    }
    final settings = _repository.appSettings();
    _readerSettings = settings?.readerSettings ?? const ReaderSettings();
    _themeMode = _themeModeFromPreference(
      settings?.themePreference ?? ThemePreference.system,
    );
    _notifyNewChapters = settings?.notifyNewChapters ?? false;
    _cacheLimitBytes = settings?.cacheLimitBytes ?? _defaultCacheLimitBytes;
    _initialRecentSearches = _repository.recentSearches();

    final route = _repository.lastRoute();
    _initialDestination = _destinationForRoute(route?.routeName);
    _currentDestination = _initialDestination;
    final restoreReader = route?.routeName == '/reader';
    _initialReaderNovelId = restoreReader ? route?.novelId : null;
    _initialReaderPosition = restoreReader ? route?.position : null;

    if (widget.contentCoordinator == null) {
      _catalogNovels = fixtureCatalogNovels;
      _recentlyUpdatedNovels = fixtureCatalogNovels;
      _catalogAvailability = CatalogAvailability.available;
      _recentlyUpdatedAvailability = CatalogAvailability.available;
      _mostClickedAvailability = CatalogAvailability.available;
    } else {
      _repository.evictCacheTo(maxBytes: _cacheLimitBytes);
      _catalogNovels = _restoreCachedCatalog();
      _recentlyUpdatedNovels = _catalogNovels;
      // Restored rows are useful immediately, but they are not evidence that
      // the service is currently reachable. A live-origin refresh promotes the
      // state to available once it actually succeeds.
      _catalogAvailability = CatalogAvailability.offline;
      _recentlyUpdatedAvailability = CatalogAvailability.offline;
      _mostClickedAvailability = CatalogAvailability.offline;
      unawaited(_refreshCatalog());
      unawaited(_refreshMostClicked());
      unawaited(_resumeDownloadIntents());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.accountSessionController?.removeListener(_accountSessionChanged);
    _catalogLoadGeneration += 1;
    _mostClickedGeneration += 1;
    _recentlyUpdatedGeneration += 1;
    widget.onRuntimeDispose?.call();
    if (widget.closeRepositoryOnDispose) _repository.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (widget.contentCoordinator != null) {
      unawaited(_refreshCatalog());
      unawaited(_refreshRecentlyUpdated());
      unawaited(_refreshMostClicked());
    }
    if (widget.downloadCoordinator != null) {
      unawaited(_resumeDownloadIntents());
    }
    if (widget.accountSessionController?.snapshot.status ==
        AccountSessionStatus.unavailable) {
      unawaited(widget.accountSessionController!.retry());
    } else if (widget.accountSessionController?.snapshot.isSignedIn == true) {
      unawaited(_refreshFavoriteFolders());
      unawaited(_flushRemoteHistory());
    }
  }

  void _accountSessionChanged() {
    if (!mounted) return;
    final session = widget.accountSessionController?.snapshot;
    _syncHistoryOutboxOwner(session);
    if (session?.isSignedIn == true) {
      unawaited(_refreshFavoriteFolders());
      unawaited(_flushRemoteHistory());
    } else {
      _favoriteFolderGeneration += 1;
      _remoteFavorites = const RemoteFavoritesViewModel.unavailable();
    }
    if (widget.contentCoordinator != null &&
        _catalogCriteria.contentLevel != CatalogContentLevel.general) {
      unawaited(_refreshCatalog(criteria: _catalogCriteria));
    }
    setState(() {});
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
            cacheAdapter.cacheOutline(
              outline,
              fetchedAt: fetchedAt,
              allowRestricted: allowRestricted,
            ),
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
    _clearHistoryOutbox();
    _historyOutboxOwner = null;
    _historyOutboxOwnerInitialized = true;
    await widget.accountSessionController?.logout();
  }

  void _syncHistoryOutboxOwner(AccountSessionSnapshot? session) {
    if (session == null) return;
    if (session.status == AccountSessionStatus.restoring &&
        session.profile == null) {
      return;
    }
    final username = session.profile?.username;
    if (!_historyOutboxOwnerInitialized) {
      _historyOutboxOwner = username;
      _historyOutboxOwnerInitialized = true;
      if (session.status == AccountSessionStatus.signedOut) {
        _clearHistoryOutbox();
      }
      return;
    }
    if (username == _historyOutboxOwner) return;
    _clearHistoryOutbox();
    _historyOutboxOwner = username;
  }

  void _clearHistoryOutbox() {
    _repository.clearRemoteHistoryOutbox();
    _lastHistoryChapterByNovel.clear();
  }

  void _queueRemoteHistory(
    ReaderNovel novel,
    ReadingPosition position,
    DateTime occurredAt,
  ) {
    if (widget.accountSessionController?.snapshot.hasStoredAccount != true ||
        widget.accountGateway == null ||
        _lastHistoryChapterByNovel[novel.id] == position.chapterId) {
      return;
    }
    final key = _serviceNovelKey(novel.id);
    if (key == null) return;
    _lastHistoryChapterByNovel[novel.id] = position.chapterId;
    _repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: novel.id,
        providerId: key.$1,
        serviceNovelId: key.$2,
        chapterId: position.chapterId,
        occurredAt: occurredAt,
      ),
    );
    unawaited(_flushRemoteHistory());
  }

  Future<void> _flushRemoteHistory() async {
    final gateway = widget.accountGateway;
    if (_historyFlushActive ||
        gateway == null ||
        widget.accountSessionController?.snapshot.isSignedIn != true) {
      return;
    }
    _historyFlushActive = true;
    try {
      while (widget.accountSessionController?.snapshot.isSignedIn == true) {
        final entries = _repository.listRemoteHistoryOutbox();
        if (entries.isEmpty) break;
        final entry = entries.first;
        try {
          await gateway.updateReadHistory(
            providerId: entry.providerId,
            novelId: entry.serviceNovelId,
            chapterId: entry.chapterId,
          );
          _repository.removeRemoteHistoryIfUnchanged(entry);
        } on Object {
          break;
        }
      }
    } finally {
      _historyFlushActive = false;
    }
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

  Future<void> _refreshCatalog({
    CatalogCriteria? criteria,
    bool append = false,
  }) async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) return;
    final requestedCriteria = criteria ?? _catalogCriteria;
    final criteriaChanged = requestedCriteria != _catalogCriteria;
    if (append &&
        (_catalogLoadingMore ||
            _catalogPageIndex < 0 ||
            _catalogPageIndex + 1 >= _catalogTotalPages)) {
      return;
    }
    final targetPage = append ? _catalogPageIndex + 1 : 0;
    final generation = append
        ? _catalogLoadGeneration
        : ++_catalogLoadGeneration;
    if (mounted && append) {
      setState(() {
        _catalogLoadingMore = true;
        _catalogLoadMoreFailed = false;
      });
    } else if (mounted && !append) {
      setState(() {
        _catalogCriteria = requestedCriteria;
        _catalogLoading = true;
        _catalogLoadingMore = false;
        _catalogLoadMoreFailed = false;
        if (criteriaChanged) {
          _catalogNovels = const [];
          _catalogPageIndex = -1;
          _catalogTotalPages = 0;
        }
      });
    }
    final base = widget.catalogQuery;
    final providers = _usesAllCatalogSources(requestedCriteria.sources)
        ? base.providers
        : [
            for (final source in requestedCriteria.sources)
              ?_providerIdForSource(source),
          ];
    final effectiveSearch = requestedCriteria.search.trim().isNotEmpty
        ? requestedCriteria.search.trim()
        : requestedCriteria.exactTag?.trim() ?? '';
    final query = NoveliaCatalogQuery(
      page: targetPage,
      pageSize: base.pageSize,
      search: effectiveSearch,
      providers: providers,
      publicationType: _publicationTypeFor(
        requestedCriteria.publicationState,
        fallback: base.publicationType,
      ),
      contentLevel: _contentLevelFor(requestedCriteria.contentLevel),
      translationFilter: _translationFilterFor(
        requestedCriteria.translationSource,
        fallback: base.translationFilter,
      ),
      sort: _sortCodeFor(requestedCriteria.sort),
    );
    try {
      final result = await coordinator.loadCatalog(query);
      if (!mounted || generation != _catalogLoadGeneration) return;
      final slice = result.data;
      setState(() {
        _catalogAvailability = result.availability;
        if (_isPlainRecentlyUpdated(requestedCriteria)) {
          _recentlyUpdatedAvailability = result.availability;
        }
        _catalogCriteria = requestedCriteria;
        _catalogLoading = false;
        _catalogLoadingMore = false;
        _catalogLoadMoreFailed = append && slice == null;
        if (slice != null) {
          final hydratedById = {
            for (final novel in _catalogNovels)
              if (novel.readerNovel != null) novel.id: novel,
          };
          final incoming = [
            for (final novel in slice.novels)
              if (_matchesUnsupportedServiceCriteria(novel, requestedCriteria))
                hydratedById[novel.id] ?? novel,
          ];
          if (append) {
            final seen = {for (final novel in _catalogNovels) novel.id};
            _catalogNovels = List.unmodifiable([
              ..._catalogNovels,
              for (final novel in incoming)
                if (seen.add(novel.id)) novel,
            ]);
          } else {
            _catalogNovels = List.unmodifiable(incoming);
            if (_isPlainRecentlyUpdated(requestedCriteria)) {
              _recentlyUpdatedNovels = _catalogNovels;
              _recentlyUpdatedPageIndex = slice.pageIndex;
              _recentlyUpdatedTotalPages = slice.totalPages;
            }
          }
          _catalogPageIndex = slice.pageIndex;
          _catalogTotalPages = slice.totalPages;
        }
      });
    } on Object {
      if (!mounted || generation != _catalogLoadGeneration) return;
      setState(() {
        _catalogLoading = false;
        _catalogLoadingMore = false;
        _catalogLoadMoreFailed = append;
        if (_catalogNovels.isEmpty) {
          _catalogAvailability = CatalogAvailability.offline;
        }
        if (_isPlainRecentlyUpdated(requestedCriteria)) {
          _recentlyUpdatedAvailability = CatalogAvailability.offline;
        }
      });
    }
  }

  Future<void> _applyCatalogCriteria(CatalogCriteria criteria) {
    return _refreshCatalog(criteria: criteria);
  }

  Future<void> _loadMoreCatalog() {
    return _refreshCatalog(append: true);
  }

  static String? _providerIdForSource(String? source) {
    return switch (source?.trim().toLowerCase()) {
      'kakuyomu' => 'kakuyomu',
      'syosetu' || '成为小说家吧' => 'syosetu',
      'novelup' => 'novelup',
      'hameln' => 'hameln',
      'pixiv' => 'pixiv',
      'alphapolis' => 'alphapolis',
      _ => null,
    };
  }

  int _contentLevelFor(CatalogContentLevel level) {
    return switch (level) {
      CatalogContentLevel.all =>
        widget.accountSessionController?.snapshot.isSignedIn == true ? 0 : 1,
      CatalogContentLevel.general => 1,
      CatalogContentLevel.r18 => 2,
    };
  }

  static int _publicationTypeFor(
    NovelPublicationState? state, {
    required int fallback,
  }) {
    return switch (state) {
      null => fallback,
      NovelPublicationState.ongoing => 1,
      NovelPublicationState.completed => 2,
      NovelPublicationState.shortStory => 3,
      // The endpoint has no "unknown" code. Query the general catalog and
      // apply this one criterion to the truthful mapped state below.
      NovelPublicationState.unknown => 0,
    };
  }

  static int _translationFilterFor(String? source, {required int fallback}) {
    return switch (source?.trim().toLowerCase()) {
      null || '' => fallback,
      'gpt' => 1,
      'sakura' => 2,
      // The service query exposes only GPT and Sakura filters. Youdao is
      // narrowed from the returned coverage metadata without inventing a code.
      _ => 0,
    };
  }

  static int _sortCodeFor(CatalogSort sort) {
    return switch (sort) {
      CatalogSort.recentlyUpdated => 0,
      CatalogSort.mostClicked => 1,
      CatalogSort.relevance => 2,
    };
  }

  static bool _matchesUnsupportedServiceCriteria(
    CatalogNovel novel,
    CatalogCriteria criteria,
  ) {
    final selectedProviders = criteria.sources
        .map(_providerIdForSource)
        .whereType<String>();
    if (!selectedProviders.contains(_providerIdForSource(novel.source))) {
      return false;
    }
    final isRestricted = novel.tags.any(
      (tag) => tag.trim().toUpperCase() == 'R18',
    );
    if (criteria.contentLevel == CatalogContentLevel.general && isRestricted) {
      return false;
    }
    if (criteria.contentLevel == CatalogContentLevel.r18 && !isRestricted) {
      return false;
    }
    final selectedState = criteria.publicationState;
    if (selectedState != null && novel.publicationState != selectedState) {
      return false;
    }
    final translationSource = criteria.translationSource;
    if (translationSource != null &&
        novel.coverageFor(translationSource)?.hasTranslation != true) {
      return false;
    }
    final exactTag = criteria.exactTag;
    if (exactTag != null && !novel.tags.contains(exactTag)) return false;
    return true;
  }

  Future<void> _refreshMostClicked({bool append = false}) async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) return;
    if (append &&
        (_mostClickedLoadingMore ||
            _mostClickedPageIndex < 0 ||
            _mostClickedPageIndex + 1 >= _mostClickedTotalPages)) {
      return;
    }
    final generation = append
        ? _mostClickedGeneration
        : ++_mostClickedGeneration;
    final targetPage = append ? _mostClickedPageIndex + 1 : 0;
    final base = widget.catalogQuery;
    if (append && mounted) {
      setState(() {
        _mostClickedLoadingMore = true;
        _mostClickedLoadMoreFailed = false;
      });
    }
    try {
      final result = await coordinator.loadCatalog(
        NoveliaCatalogQuery(
          page: targetPage,
          pageSize: base.pageSize,
          providers: base.providers,
          contentLevel: base.contentLevel,
          sort: 1,
        ),
      );
      if (!mounted || generation != _mostClickedGeneration) return;
      final data = result.data;
      setState(() {
        _mostClickedAvailability = result.availability;
        _mostClickedLoadingMore = false;
        _mostClickedLoadMoreFailed = append && data == null;
        if (data == null || result.origin != NoveliaContentOrigin.live) return;
        _mostClickedNovels = append
            ? _appendUniqueNovels(_mostClickedNovels, data.novels)
            : List.unmodifiable(data.novels);
        _mostClickedPageIndex = data.pageIndex;
        _mostClickedTotalPages = data.totalPages;
      });
    } on Object {
      if (!mounted || generation != _mostClickedGeneration) return;
      setState(() {
        _mostClickedAvailability = CatalogAvailability.offline;
        _mostClickedLoadingMore = false;
        _mostClickedLoadMoreFailed = append;
      });
    }
  }

  Future<void> _refreshRecentlyUpdated({bool append = false}) async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) return;
    if (append &&
        (_recentlyUpdatedLoadingMore ||
            _recentlyUpdatedPageIndex < 0 ||
            _recentlyUpdatedPageIndex + 1 >= _recentlyUpdatedTotalPages)) {
      return;
    }
    final generation = append
        ? _recentlyUpdatedGeneration
        : ++_recentlyUpdatedGeneration;
    final targetPage = append ? _recentlyUpdatedPageIndex + 1 : 0;
    final base = widget.catalogQuery;
    if (append && mounted) {
      setState(() {
        _recentlyUpdatedLoadingMore = true;
        _recentlyUpdatedLoadMoreFailed = false;
      });
    }
    try {
      final result = await coordinator.loadCatalog(
        NoveliaCatalogQuery(
          page: targetPage,
          pageSize: base.pageSize,
          providers: base.providers,
          contentLevel: base.contentLevel,
          sort: 0,
        ),
      );
      if (!mounted || generation != _recentlyUpdatedGeneration) return;
      final data = result.data;
      setState(() {
        _recentlyUpdatedAvailability = result.availability;
        _recentlyUpdatedLoadingMore = false;
        _recentlyUpdatedLoadMoreFailed = append && data == null;
        if (data == null) return;
        _recentlyUpdatedNovels = append
            ? _appendUniqueNovels(_recentlyUpdatedNovels, data.novels)
            : List.unmodifiable(data.novels);
        _recentlyUpdatedPageIndex = data.pageIndex;
        _recentlyUpdatedTotalPages = data.totalPages;
      });
    } on Object {
      if (!mounted || generation != _recentlyUpdatedGeneration) return;
      setState(() {
        _recentlyUpdatedAvailability = CatalogAvailability.offline;
        _recentlyUpdatedLoadingMore = false;
        _recentlyUpdatedLoadMoreFailed = append;
      });
    }
  }

  static List<CatalogNovel> _appendUniqueNovels(
    List<CatalogNovel> current,
    List<CatalogNovel> incoming,
  ) {
    final seen = {for (final novel in current) novel.id};
    return List.unmodifiable([
      ...current,
      for (final novel in incoming)
        if (seen.add(novel.id)) novel,
    ]);
  }

  Future<void> _refreshDiscoveryFeeds() async {
    await Future.wait([_refreshRecentlyUpdated(), _refreshMostClicked()]);
  }

  Future<void> _loadMoreDiscovery(CatalogSort sort) {
    return sort == CatalogSort.mostClicked
        ? _refreshMostClicked(append: true)
        : _refreshRecentlyUpdated(append: true);
  }

  static bool _isPlainRecentlyUpdated(CatalogCriteria criteria) {
    return criteria.search.trim().isEmpty &&
        _usesAllCatalogSources(criteria.sources) &&
        criteria.publicationState == null &&
        criteria.contentLevel == CatalogContentLevel.all &&
        criteria.translationSource == null &&
        criteria.exactTag == null &&
        criteria.sort == CatalogSort.recentlyUpdated;
  }

  static bool _usesAllCatalogSources(List<String> sources) {
    final selected = sources.toSet();
    return selected.length == catalogSourceValues.length &&
        selected.containsAll(catalogSourceValues);
  }

  CatalogAvailability get _discoveryAvailability {
    final feeds = [_recentlyUpdatedAvailability, _mostClickedAvailability];
    if (feeds.contains(CatalogAvailability.available)) {
      return CatalogAvailability.available;
    }
    if (feeds.contains(CatalogAvailability.authenticationRequired)) {
      return CatalogAvailability.authenticationRequired;
    }
    return CatalogAvailability.offline;
  }

  CatalogAvailability get _searchAvailability {
    if (_catalogAvailability == CatalogAvailability.authenticationRequired) {
      return CatalogAvailability.authenticationRequired;
    }
    if (_catalogAvailability == CatalogAvailability.offline &&
        _discoveryAvailability == CatalogAvailability.available) {
      return CatalogAvailability.available;
    }
    return _catalogAvailability;
  }

  Future<RankingPageView> _loadRankings(RankingsQuery query) async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) {
      throw StateError('No ranking loader is configured.');
    }
    final providerId = _rankingProviderId(query.source);
    final range = _rankingRange(query.period);
    final kakuyomu = providerId == 'kakuyomu';
    final result = await coordinator.loadRankings(
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
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) {
      if (outline.readerNovel != null) return outline;
      throw StateError('No detail loader is configured.');
    }
    final result = await coordinator.loadDetails(outline);
    final loaded = result.data;
    if (loaded == null) {
      throw result.failure ?? StateError('Novel details are unavailable.');
    }
    if (mounted) {
      // Do not rebuild the app-level Navigator while its detail loader is
      // completing. The hydrated aggregate is picked up on the next ordinary
      // state change, while the active route receives [loaded] directly.
      _catalogNovels = List.unmodifiable([
        for (final novel in _catalogNovels)
          if (novel.id == loaded.id) loaded else novel,
      ]);
    }
    return loaded;
  }

  Future<ReaderLaunchData> _loadReaderWindow(
    CatalogNovel novel,
    NovelChapter? selectedChapter,
    ReadingPosition? requestedPosition,
  ) async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) {
      final readerNovel = novel.readerNovel;
      if (readerNovel == null) {
        throw StateError('No reader content is configured.');
      }
      return ReaderLaunchData(
        novel: readerNovel,
        initialPosition: requestedPosition,
        startAtChapterTitle: requestedPosition == null,
      );
    }
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
          contentCoordinator: coordinator,
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
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) {
      return NovelCommentPage(
        pageNumber: pageNumber,
        totalPages: novel.comments.isEmpty ? 0 : 1,
        totalComments: novel.comments.length,
        comments: novel.comments,
      );
    }
    final result = await coordinator.loadComments(
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
      if (mounted) setState(() {});
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
        notifyNewChapters: _notifyNewChapters,
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
    if (mounted) setState(() {});
  }

  Future<int> _clearReadingCache() async {
    final removed = _repository.evictCacheTo(maxBytes: 0);
    if (mounted) setState(() {});
    return removed.length;
  }

  void _saveTopLevelRoute(int destination) {
    _currentDestination = destination;
    _repository.saveLastRoute(
      LastRouteState(
        routeName: _routeForDestination(destination),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void _saveReaderPosition(
    ReaderNovel novel,
    ReadingPosition position, {
    bool syncRemoteHistory = true,
  }) {
    final now = DateTime.now().toUtc();
    _saveProgressOnly(novel, position, now);
    if (syncRemoteHistory) _queueRemoteHistory(novel, position, now);
    _touchChapterCopies(novel.id, position.chapterId, now);
    _repository.evictCacheTo(
      maxBytes: _cacheLimitBytes,
      protectedChapters: {
        ChapterRef(novelId: novel.id, chapterId: position.chapterId),
      },
    );
    _repository.saveLastRoute(
      LastRouteState(
        routeName: '/reader',
        novelId: novel.id,
        position: position,
        updatedAt: now,
      ),
    );
  }

  void _touchChapterCopies(String novelId, String chapterId, DateTime readAt) {
    for (final copy in _repository.listCopies(novelId: novelId)) {
      if (copy.chapterId == chapterId && !readAt.isBefore(copy.lastReadAt)) {
        _repository.touchCopy(copy.id, readAt);
      }
    }
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
    if (widget.downloadCoordinator == null) {
      _downloadFixtureNovel(novel);
      return;
    }
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
    if (mounted) setState(() {});
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

    if (mounted) setState(() {});
    if (action == DownloadManagementAction.remove) return null;
    final updated = _libraryDownloads(_localNovelsById());
    return updated
        .where((candidate) => candidate.groupKey == download.groupKey)
        .firstOrNull;
  }

  void _downloadFixtureNovel(CatalogNovel novel) {
    final readerNovel = novel.readerNovel;
    if (readerNovel == null || readerNovel.chapters.isEmpty) {
      throw StateError('Novel details must be loaded before downloading.');
    }
    final source = _readerSettings.translationSource;
    final now = DateTime.now().toUtc();
    final intentId = [
      'novel',
      novel.id,
      source.name,
    ].map(Uri.encodeComponent).join('::');
    _repository.saveIntent(
      NovelDownloadIntent(
        id: intentId,
        novelId: novel.id,
        translationSource: source,
        createdAt: now,
      ),
    );
    final tasks = _repository.reconcileIntent(
      intentId: intentId,
      knownChapterIds: readerNovel.chapters.map((chapter) => chapter.id),
      now: now,
    );
    for (final initialTask in tasks) {
      final chapter = readerNovel.chapters.firstWhere(
        (chapter) => chapter.id == initialTask.chapterId,
      );
      _storeFixtureChapter(initialTask, chapter, now);
    }
  }

  void _storeFixtureChapter(
    DownloadTask initialTask,
    NovelChapter chapter,
    DateTime now,
  ) {
    final source = initialTask.translationSource;
    final originalBytes = chapter.blocks.fold<int>(
      0,
      (total, block) => total + utf8.encode(block.japanese).length,
    );
    final state = chapter.translationState(source);
    final translationBytes = state == TranslationState.complete
        ? chapter.blocks.fold<int>(
            0,
            (total, block) =>
                total + utf8.encode(block.translations[source] ?? '').length,
          )
        : null;
    final totalBytes = originalBytes + (translationBytes ?? 0);

    var task = initialTask.beginFetching(now, expectedBytes: totalBytes);
    _repository.saveTask(task);
    task = task.reportFetchProgress(now, bytesReceived: totalBytes);
    _repository.saveTask(task);
    task = task.beginValidation(now);
    _repository.saveTask(task);
    if (state == TranslationState.invalid) {
      _repository.saveTask(
        task.fail(
          now,
          const DownloadFailure(
            kind: DownloadFailureKind.validation,
            message: 'Translation alignment is invalid.',
            retryable: false,
          ),
        ),
      );
      return;
    }
    task = task.beginStoring(now);
    _repository.saveTask(task);
    _repository.commitStoredTask(
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

  Map<String, CatalogNovel> _localNovelsById() {
    const adapter = NoveliaContentCacheAdapter();
    final allowRestricted =
        widget.accountSessionController?.snapshot.isSignedIn == true;
    final result = <String, CatalogNovel>{};
    for (final cached in _repository.listCachedNovels()) {
      try {
        result[cached.id] = adapter.restoreOutline(
          cached,
          allowRestricted: allowRestricted,
        );
        final detail = _repository.novelDetail(cached.id);
        if (detail != null) {
          result[cached.id] = adapter.restoreDetails(
            detail,
            allowRestricted: allowRestricted,
          );
        }
      } on Object {
        // Omit a malformed local title without hiding unrelated local state.
      }
    }
    for (final novel in _catalogNovels) {
      final existing = result[novel.id];
      if (existing == null || novel.readerNovel != null) {
        result[novel.id] = novel;
      }
    }
    return result;
  }

  List<LibraryContinuedRead> _libraryContinuedReads(
    Map<String, CatalogNovel> novelsById,
  ) {
    final progress = _repository.listReadingProgress().toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable([
      for (final item in progress)
        if (novelsById[item.novelId] case final novel?)
          LibraryContinuedRead(
            novel: novel,
            position: item.position,
            progress: _readingFraction(novel, item.position),
            chapterLabel: _chapterLabel(novel, item.position.chapterId),
          ),
    ]);
  }

  double _readingFraction(CatalogNovel novel, ReadingPosition position) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    final chapterIndex = chapters.indexWhere(
      (chapter) => chapter.id == position.chapterId,
    );
    if (chapterIndex < 0) return 0;
    final payload = _repository.chapterPayload(
      novelId: novel.id,
      chapterId: position.chapterId,
    );
    final blockCount = payload?.japaneseBlocks.length ?? 0;
    final separator = position.blockId.lastIndexOf(':');
    final ordinal = separator < 0
        ? null
        : int.tryParse(position.blockId.substring(separator + 1));
    final chapterFraction = blockCount <= 0 || ordinal == null
        ? 0.0
        : ((ordinal + 1) / blockCount).clamp(0.0, 1.0);
    return ((chapterIndex + chapterFraction) / chapters.length).clamp(0.0, 1.0);
  }

  String? _chapterLabel(CatalogNovel novel, String chapterId) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return null;
    for (final chapter in chapters) {
      if (chapter.id == chapterId) {
        return chapter.chineseTitle.isEmpty
            ? chapter.japaneseTitle
            : chapter.chineseTitle;
      }
    }
    return null;
  }

  List<LibraryProtectedDownload> _libraryDownloads(
    Map<String, CatalogNovel> novelsById,
  ) {
    final intentsByGroup =
        <(String, TranslationSource), List<DownloadIntent>>{};
    for (final intent in _repository.listIntents()) {
      final group = (intent.novelId, intent.translationSource);
      intentsByGroup.putIfAbsent(group, () => []).add(intent);
    }

    final copiesByGroup =
        <(String, TranslationSource), Map<String, OfflineChapterCopy>>{};
    for (final copy in _repository.listCopies(
      kind: OfflineCopyKind.offlineDownload,
    )) {
      final group = (copy.novelId, copy.translationSource);
      final copies = copiesByGroup.putIfAbsent(group, () => {});
      final existing = copies[copy.chapterId];
      if (existing == null || copy.storedAt.isAfter(existing.storedAt)) {
        copies[copy.chapterId] = copy;
      }
    }

    final tasksByGroup =
        <(String, TranslationSource), Map<String, DownloadTask>>{};
    for (final task in _repository.listTasks()) {
      if (task.state == DownloadTaskState.removed) continue;
      final group = (task.novelId, task.translationSource);
      final tasks = tasksByGroup.putIfAbsent(group, () => {});
      final existing = tasks[task.chapterId];
      if (existing == null || task.updatedAt.isAfter(existing.updatedAt)) {
        tasks[task.chapterId] = task;
      }
    }

    final groups =
        {
          ...intentsByGroup.keys,
          ...copiesByGroup.keys,
          ...tasksByGroup.keys,
        }.toList()..sort((a, b) {
          final novelOrder = a.$1.compareTo(b.$1);
          return novelOrder == 0
              ? a.$2.index.compareTo(b.$2.index)
              : novelOrder;
        });
    final downloads = <LibraryProtectedDownload>[];
    for (final group in groups) {
      final novel = novelsById[group.$1];
      if (novel == null) continue;
      final intents = intentsByGroup[group] ?? const [];
      final copies = copiesByGroup[group] ?? const {};
      final tasks = tasksByGroup[group] ?? const {};
      final chapterIds = {...copies.keys, ...tasks.keys}.toList()
        ..sort((a, b) {
          final aIndex = _chapterCatalogIndex(novel, a);
          final bIndex = _chapterCatalogIndex(novel, b);
          final order = aIndex.compareTo(bIndex);
          return order == 0 ? a.compareTo(b) : order;
        });
      downloads.add(
        LibraryProtectedDownload(
          novel: novel,
          translationSource: group.$2,
          intentIds: [for (final intent in intents) intent.id],
          enabled: intents.any((intent) => intent.enabled),
          chapters: [
            for (final chapterId in chapterIds)
              _libraryDownloadChapter(
                chapterId,
                copy: copies[chapterId],
                task: tasks[chapterId],
              ),
          ],
        ),
      );
    }
    return List.unmodifiable(downloads);
  }

  static LibraryDownloadChapter _libraryDownloadChapter(
    String chapterId, {
    required OfflineChapterCopy? copy,
    required DownloadTask? task,
  }) {
    final storedBytes = copy?.totalBytes;
    final state = _displayTaskState(copy, task);
    return LibraryDownloadChapter(
      chapterId: chapterId,
      byteCount: storedBytes ?? 0,
      translationAvailable: copy?.translationBytes != null,
      taskState: state,
      bytesReceived: state == DownloadTaskState.stored
          ? storedBytes ?? task?.bytesReceived ?? 0
          : task?.bytesReceived ?? 0,
      totalBytes: state == DownloadTaskState.stored
          ? storedBytes ?? task?.totalBytes
          : task?.totalBytes,
      failure: task?.failure,
    );
  }

  static DownloadTaskState _displayTaskState(
    OfflineChapterCopy? copy,
    DownloadTask? task,
  ) {
    if (copy != null &&
        (task == null ||
            task.state == DownloadTaskState.stored ||
            task.storedCopyId != copy.id)) {
      return DownloadTaskState.stored;
    }
    return task?.state ?? DownloadTaskState.stored;
  }

  static int _chapterCatalogIndex(CatalogNovel novel, String chapterId) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return 1 << 30;
    final index = chapters.indexWhere((chapter) => chapter.id == chapterId);
    return index < 0 ? 1 << 30 : index;
  }

  List<LibraryBookmarkItem> _libraryBookmarks(
    Map<String, CatalogNovel> novelsById,
  ) {
    final bookmarks = _repository.listBookmarks().toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable([
      for (final bookmark in bookmarks)
        if (novelsById[bookmark.novelId] case final novel?)
          LibraryBookmarkItem(
            id: bookmark.id,
            novel: novel,
            position: bookmark.position,
            chapterLabel: _chapterLabel(novel, bookmark.position.chapterId),
          ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final localNovelsById = _localNovelsById();
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
      home: NoveliaShell(
        wenkuGateway: widget.wenkuGateway,
        appVersion: widget.appVersion,
        novels: _catalogNovels,
        catalogAvailability: _searchAvailability,
        discoveryAvailability: _discoveryAvailability,
        continuedReads: _libraryContinuedReads(localNovelsById),
        protectedDownloads: _libraryDownloads(localNovelsById),
        bookmarks: _libraryBookmarks(localNovelsById),
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
        storageSummary: _repository.storageSummary(),
        cacheLimitBytes: _cacheLimitBytes,
        onCacheLimitChanged: _setCacheLimit,
        onClearReadingCache: _clearReadingCache,
        initialCatalogCriteria: _catalogCriteria,
        onCatalogCriteriaRequested: widget.contentCoordinator == null
            ? null
            : _applyCatalogCriteria,
        onCatalogLoadMoreRequested: widget.contentCoordinator == null
            ? null
            : _loadMoreCatalog,
        onDiscoveryRefreshRequested: widget.contentCoordinator == null
            ? null
            : _refreshDiscoveryFeeds,
        onDiscoveryLoadMoreRequested: widget.contentCoordinator == null
            ? null
            : _loadMoreDiscovery,
        catalogHasMore:
            _catalogPageIndex >= 0 &&
            _catalogPageIndex + 1 < _catalogTotalPages,
        catalogLoading: _catalogLoading,
        catalogLoadingMore: _catalogLoadingMore,
        catalogLoadMoreFailed: _catalogLoadMoreFailed,
        recentlyUpdatedHasMore:
            _recentlyUpdatedPageIndex >= 0 &&
            _recentlyUpdatedPageIndex + 1 < _recentlyUpdatedTotalPages,
        recentlyUpdatedLoadingMore: _recentlyUpdatedLoadingMore,
        recentlyUpdatedLoadMoreFailed: _recentlyUpdatedLoadMoreFailed,
        mostClickedHasMore:
            _mostClickedPageIndex >= 0 &&
            _mostClickedPageIndex + 1 < _mostClickedTotalPages,
        mostClickedLoadingMore: _mostClickedLoadingMore,
        mostClickedLoadMoreFailed: _mostClickedLoadMoreFailed,
        mostClickedNovels: _mostClickedNovels,
        recentlyUpdatedNovels: _recentlyUpdatedNovels,
        rankingsLoader: widget.contentCoordinator == null
            ? null
            : _loadRankings,
        novelDetailsLoader: widget.contentCoordinator == null
            ? null
            : _loadNovelDetails,
        readerLaunchLoader: widget.contentCoordinator == null
            ? null
            : _loadReaderWindow,
        commentPageLoader: widget.contentCoordinator == null
            ? null
            : _loadCommentPage,
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
          _saveTopLevelRoute(_currentDestination);
          // Reader callbacks persist progress and bookmarks outside this
          // widget's state. Rebuild once after the route closes so Library and
          // Settings immediately project the newly committed local rows.
          if (mounted) setState(() {});
        },
        onDownloadRequested: _downloadNovel,
        onDownloadManagementRequested: _manageDownload,
        downloadManagementSnapshotLoader: () =>
            _libraryDownloads(_localNovelsById()),
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
