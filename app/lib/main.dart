import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/database/local_state_repository.dart';
import 'core/database/sqlite_offline_repository.dart';
import 'core/model/reader_models.dart';
import 'core/offline/offline_models.dart';
import 'features/discover/catalog_models.dart';
import 'features/discover/rankings_screen.dart';
import 'features/reader/reader_screen.dart';
import 'features/shell/novelia_shell.dart';
import 'features/shell/shell_view_models.dart';
import 'fixtures/catalog_fixture.dart';
import 'gateway/novelia/http_novelia_gateway.dart';
import 'gateway/novelia/novelia_content_cache_adapter.dart';
import 'gateway/novelia/novelia_content_coordinator.dart';
import 'gateway/novelia/novelia_download_coordinator.dart';
import 'gateway/novelia/novelia_gateway.dart';
import 'gateway/novelia/novelia_reader_window.dart';

const _defaultCacheLimitBytes = 256 * 1024 * 1024;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final repository = await SqliteOfflineRepository.openApplicationSupport();
    final gateway = HttpNoveliaGateway();
    final contentCoordinator = LiveFirstNoveliaContentCoordinator(
      gateway: gateway,
      contentRepository: repository,
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
    );
    runApp(
      NoveliaReaderApp(
        repository: repository,
        contentCoordinator: contentCoordinator,
        downloadCoordinator: downloadCoordinator,
        closeRepositoryOnDispose: true,
        onRuntimeDispose: gateway.close,
      ),
    );
  } on Object {
    runApp(const _DatabaseUnavailableApp());
  }
}

class NoveliaReaderApp extends StatefulWidget {
  const NoveliaReaderApp({
    required this.repository,
    this.contentCoordinator,
    this.downloadCoordinator,
    this.catalogQuery = const NoveliaCatalogQuery(),
    this.onRuntimeDispose,
    this.closeRepositoryOnDispose = false,
    super.key,
  });

  final SqliteOfflineRepository repository;
  final NoveliaContentCoordinator? contentCoordinator;
  final NoveliaDownloadCoordinator? downloadCoordinator;
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
  late CatalogAvailability _catalogAvailability;
  final Set<String> _activeDownloadSyncs = <String>{};
  var _catalogLoadGeneration = 0;
  var _catalogPageIndex = -1;
  var _catalogTotalPages = 0;
  var _catalogCriteria = const CatalogCriteria();
  var _catalogLoadingMore = false;
  var _catalogLoadMoreFailed = false;
  var _mostClickedNovels = const <CatalogNovel>[];
  var _mostClickedGeneration = 0;
  var _currentDestination = 0;

  SqliteOfflineRepository get _repository => widget.repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      _catalogAvailability = CatalogAvailability.available;
    } else {
      _repository.evictCacheTo(maxBytes: _cacheLimitBytes);
      _catalogNovels = _restoreCachedCatalog();
      // Restored rows are useful immediately, but they are not evidence that
      // the service is currently reachable. A live-origin refresh promotes the
      // state to available once it actually succeeds.
      _catalogAvailability = CatalogAvailability.offline;
      unawaited(_refreshCatalog());
      unawaited(_refreshMostClicked());
      unawaited(_resumeDownloadIntents());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _catalogLoadGeneration += 1;
    _mostClickedGeneration += 1;
    widget.onRuntimeDispose?.call();
    if (widget.closeRepositoryOnDispose) _repository.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (widget.contentCoordinator != null) {
      unawaited(_refreshCatalog());
      unawaited(_refreshMostClicked());
    }
    if (widget.downloadCoordinator != null) {
      unawaited(_resumeDownloadIntents());
    }
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
    final provider = _providerIdForSource(requestedCriteria.source);
    final effectiveSearch = requestedCriteria.search.trim().isNotEmpty
        ? requestedCriteria.search.trim()
        : requestedCriteria.exactTag?.trim() ?? '';
    final query = NoveliaCatalogQuery(
      page: targetPage,
      pageSize: base.pageSize,
      search: effectiveSearch,
      providers: provider == null ? base.providers : [provider],
      publicationType: _publicationTypeFor(
        requestedCriteria.publicationState,
        fallback: base.publicationType,
      ),
      contentLevel: base.contentLevel,
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
        _catalogCriteria = requestedCriteria;
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
          }
          _catalogPageIndex = slice.pageIndex;
          _catalogTotalPages = slice.totalPages;
        }
      });
    } on Object {
      if (!mounted || generation != _catalogLoadGeneration) return;
      setState(() {
        _catalogLoadingMore = false;
        _catalogLoadMoreFailed = append;
        if (_catalogNovels.isEmpty) {
          _catalogAvailability = CatalogAvailability.offline;
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
      'syosetu' => 'syosetu',
      'novelup' => 'novelup',
      'hameln' => 'hameln',
      'pixiv' => 'pixiv',
      'alphapolis' => 'alphapolis',
      _ => null,
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
    final selectedSource = criteria.source;
    if (selectedSource != null && novel.source != selectedSource) return false;
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

  Future<void> _refreshMostClicked() async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) return;
    final generation = ++_mostClickedGeneration;
    final base = widget.catalogQuery;
    try {
      final result = await coordinator.loadCatalog(
        NoveliaCatalogQuery(
          pageSize: 8,
          providers: base.providers,
          contentLevel: base.contentLevel,
          sort: 1,
        ),
      );
      if (!mounted || generation != _mostClickedGeneration) return;
      final data = result.data;
      if (data != null && result.origin == NoveliaContentOrigin.live) {
        setState(() => _mostClickedNovels = List.unmodifiable(data.novels));
      }
    } on Object {
      // Popularity order cannot be reconstructed truthfully from cached rows.
    }
  }

  Future<RankingPageView> _loadDefaultRankings() async {
    final coordinator = widget.contentCoordinator;
    if (coordinator == null) {
      throw StateError('No ranking loader is configured.');
    }
    final result = await coordinator.loadRankings(
      NoveliaRankingQuery.syosetu(
        type: '流派',
        genre: '恋爱：异世界',
        range: '总计',
        status: '全部',
        page: 1,
      ),
    );
    final slice = result.data;
    if (slice == null) {
      throw result.failure ?? StateError('Rankings are unavailable.');
    }
    return RankingPageView(
      novels: slice.novels,
      pageNumber: slice.pageIndex + 1,
      totalPages: slice.totalPages,
      description: 'Syosetu · 恋爱：异世界 · 总计 · 服务原生排序',
    );
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
    if (coordinator == null || !_activeDownloadSyncs.add(intentId)) return null;
    try {
      if (retryFailures) {
        final now = DateTime.now().toUtc();
        _repository.requeueInterruptedTasks(intentId: intentId, now: now);
      }
      return await coordinator.synchronizeIntent(intentId);
    } on Object {
      return null;
    } finally {
      _activeDownloadSyncs.remove(intentId);
      if (mounted) setState(() {});
    }
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

  void _saveTopLevelRoute(int destination) {
    _currentDestination = destination;
    _repository.saveLastRoute(
      LastRouteState(
        routeName: _routeForDestination(destination),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void _saveReaderPosition(ReaderNovel novel, ReadingPosition position) {
    final now = DateTime.now().toUtc();
    _saveProgressOnly(novel, position, now);
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
          candidate.translationSource == source &&
          candidate.enabled) {
        intent = candidate;
        break;
      }
    }
    final now = DateTime.now().toUtc();
    intent ??= NovelDownloadIntent(
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
    final run = await _synchronizeIntent(intent.id, retryFailures: true);
    if (run == null) {
      throw StateError('The download is already running or unavailable.');
    }
    if (run.availability != CatalogAvailability.available) {
      throw run.failure ?? StateError('The download source is unavailable.');
    }
    final failed = run.tasks.where(
      (task) => task.state == DownloadTaskState.failed,
    );
    if (failed.isNotEmpty) {
      throw StateError('${failed.length} chapters failed to download.');
    }
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
    final result = <String, CatalogNovel>{};
    for (final cached in _repository.listCachedNovels()) {
      try {
        result[cached.id] = adapter.restoreOutline(cached);
        final detail = _repository.novelDetail(cached.id);
        if (detail != null) result[cached.id] = adapter.restoreDetails(detail);
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

    final groups = {...copiesByGroup.keys, ...tasksByGroup.keys}.toList()
      ..sort((a, b) {
        final novelOrder = a.$1.compareTo(b.$1);
        return novelOrder == 0 ? a.$2.index.compareTo(b.$2.index) : novelOrder;
      });
    final downloads = <LibraryProtectedDownload>[];
    for (final group in groups) {
      final novel = novelsById[group.$1];
      if (novel == null) continue;
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
          chapters: [
            for (final chapterId in chapterIds)
              LibraryDownloadChapter(
                chapterId: chapterId,
                byteCount: copies[chapterId]?.totalBytes ?? 0,
                translationAvailable:
                    copies[chapterId]?.translationBytes != null,
                taskState: _displayTaskState(
                  copies[chapterId],
                  tasks[chapterId],
                ),
              ),
          ],
        ),
      );
    }
    return List.unmodifiable(downloads);
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
      title: 'Novelia 阅读器',
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'novelia-reader-app',
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
        novels: _catalogNovels,
        catalogAvailability: _catalogAvailability,
        continuedReads: _libraryContinuedReads(localNovelsById),
        protectedDownloads: _libraryDownloads(localNovelsById),
        bookmarks: _libraryBookmarks(localNovelsById),
        remoteFavorites: const RemoteFavoritesViewModel.unavailable(),
        storageSummary: _repository.storageSummary(),
        cacheLimitBytes: _cacheLimitBytes,
        initialCatalogCriteria: _catalogCriteria,
        onCatalogCriteriaRequested: widget.contentCoordinator == null
            ? null
            : _applyCatalogCriteria,
        onCatalogLoadMoreRequested: widget.contentCoordinator == null
            ? null
            : _loadMoreCatalog,
        catalogHasMore:
            _catalogPageIndex >= 0 &&
            _catalogPageIndex + 1 < _catalogTotalPages,
        catalogLoadingMore: _catalogLoadingMore,
        catalogLoadMoreFailed: _catalogLoadMoreFailed,
        mostClickedNovels: _mostClickedNovels,
        rankingsLoader: widget.contentCoordinator == null
            ? null
            : _loadDefaultRankings,
        novelDetailsLoader: widget.contentCoordinator == null
            ? null
            : _loadNovelDetails,
        readerLaunchLoader: widget.contentCoordinator == null
            ? null
            : _loadReaderWindow,
        commentPageLoader: widget.contentCoordinator == null
            ? null
            : _loadCommentPage,
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
            _saveReaderPosition(readerNovel, position);
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
        readerBuilder: (context, data) {
          final novel = data.novel;
          // The shell has already resolved explicit chapter selection, saved
          // progress, and the first-readable-block fallback. Reconsulting the
          // repository here can override an explicit chapter tap with an older
          // saved position from a different chapter.
          final initialPosition = data.initialPosition;
          final bookmarkedBlocks = _repository
              .listBookmarks(novelId: novel.id)
              .map((bookmark) => bookmark.position.blockId)
              .toSet();
          return ReaderScreen(
            novel: novel,
            initialPosition: initialPosition,
            initialBookmarkedBlockIds: bookmarkedBlocks,
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
    '/library' => 1,
    '/settings' => 2,
    _ => 0,
  };

  static String _routeForDestination(int destination) => switch (destination) {
    1 => '/library',
    2 => '/settings',
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
