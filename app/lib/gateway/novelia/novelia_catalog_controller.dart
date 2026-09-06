import 'package:flutter/foundation.dart';

import '../../features/discover/catalog_models.dart';
import 'novelia_content_coordinator.dart';
import 'novelia_gateway.dart';

/// Read-only view of one independently paginated catalog feed.
class CatalogFeed {
  CatalogFeed([List<CatalogNovel> initialNovels = const []])
    : _novels = List.unmodifiable(initialNovels);

  List<CatalogNovel> _novels;
  CatalogAvailability _availability = CatalogAvailability.offline;
  int _pageIndex = -1;
  int _totalPages = 0;
  int _generation = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;

  List<CatalogNovel> get novels => _novels;
  CatalogAvailability get availability => _availability;
  bool get hasMore => _pageIndex >= 0 && _pageIndex + 1 < _totalPages;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get loadMoreFailed => _loadMoreFailed;
}

/// Owns feed pagination and filtering. Search never writes discovery state.
class NoveliaCatalogController extends ChangeNotifier {
  NoveliaCatalogController({
    required this.contentCoordinator,
    required this.canAccessRestrictedContent,
    this.baseQuery = const NoveliaCatalogQuery(),
    List<CatalogNovel> initialNovels = const [],
    this.onContentChanged,
  }) : catalog = CatalogFeed(initialNovels),
       recentlyUpdated = CatalogFeed(initialNovels);

  final NoveliaContentCoordinator contentCoordinator;
  final bool Function() canAccessRestrictedContent;
  final NoveliaCatalogQuery baseQuery;
  final VoidCallback? onContentChanged;
  final CatalogFeed catalog;
  final CatalogFeed recentlyUpdated;
  final CatalogFeed mostClicked = CatalogFeed();
  CatalogCriteria _criteria = const CatalogCriteria();
  CatalogCriteria get criteria => _criteria;
  bool _disposed = false;
  final _requests =
      <String, Future<NoveliaContentResult<NoveliaCatalogSlice>>>{};

  Future<void> refreshCatalog({
    CatalogCriteria? criteria,
    bool append = false,
  }) {
    final requestedCriteria = criteria ?? _criteria;
    final changed = requestedCriteria != _criteria;
    _criteria = requestedCriteria;
    final targetPage = append ? catalog._pageIndex + 1 : 0;
    final base = baseQuery;
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
    return _refresh(
      catalog,
      query,
      append: append,
      criteria: requestedCriteria,
      clear: changed,
    );
  }

  Future<void> refreshRecentlyUpdated({bool append = false}) =>
      _refreshDiscovery(recentlyUpdated, sort: 0, append: append);

  Future<void> refreshMostClicked({bool append = false}) =>
      _refreshDiscovery(mostClicked, sort: 1, append: append);

  Future<void> _refreshDiscovery(
    CatalogFeed feed, {
    required int sort,
    required bool append,
  }) => _refresh(
    feed,
    NoveliaCatalogQuery(
      page: append ? feed._pageIndex + 1 : 0,
      pageSize: baseQuery.pageSize,
      providers: baseQuery.providers,
      contentLevel: baseQuery.contentLevel,
      sort: sort,
    ),
    append: append,
  );

  Future<void> _refresh(
    CatalogFeed feed,
    NoveliaCatalogQuery query, {
    required bool append,
    CatalogCriteria? criteria,
    bool clear = false,
  }) async {
    if (_disposed ||
        (append && (feed._loading || feed._loadingMore || !feed.hasMore))) {
      return;
    }
    final generation = append ? feed._generation : ++feed._generation;
    feed._loading = !append;
    feed._loadingMore = append;
    feed._loadMoreFailed = false;
    if (clear) {
      feed._novels = const [];
      feed._pageIndex = -1;
      feed._totalPages = 0;
    }
    notifyListeners();
    try {
      final result = await _load(query);
      if (_disposed || generation != feed._generation) return;
      feed._availability = result.availability;
      final slice = result.data;
      // Local outlines have no popularity ordering, so cannot replace this feed.
      final usable =
          slice != null &&
          (feed != mostClicked || result.origin == NoveliaContentOrigin.live);
      feed._loadMoreFailed = append && !usable;
      if (usable) {
        final hydrated = {
          for (final novel in feed._novels)
            if (novel.readerNovel != null) novel.id: novel,
        };
        final incoming = [
          for (final novel in slice.novels)
            if (criteria == null ||
                _matchesUnsupportedServiceCriteria(novel, criteria))
              hydrated[novel.id] ?? novel,
        ];
        final seen = {
          if (append)
            for (final novel in feed._novels) novel.id,
        };
        feed._novels = List.unmodifiable([
          if (append) ...feed._novels,
          for (final novel in incoming)
            if (seen.add(novel.id)) novel,
        ]);
        feed._pageIndex = slice.pageIndex;
        feed._totalPages = slice.totalPages;
        onContentChanged?.call();
      }
    } on Object {
      if (_disposed || generation != feed._generation) return;
      if (feed != catalog || feed._novels.isEmpty) {
        feed._availability = CatalogAvailability.offline;
      }
      feed._loadMoreFailed = append;
    } finally {
      if (!_disposed && generation == feed._generation) {
        feed._loading = false;
        feed._loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<NoveliaContentResult<NoveliaCatalogSlice>> _load(
    NoveliaCatalogQuery query,
  ) {
    // Startup and resume can request the same general feed for two destinations.
    // Share only that in-flight request; each feed commits its own pagination.
    final key = Uri(queryParameters: query.toQueryParameters()).query;
    return _requests.putIfAbsent(key, () {
      return contentCoordinator.loadCatalog(query).whenComplete(() {
        _requests.remove(key);
      });
    });
  }

  void rememberDetails(CatalogNovel novel) {
    catalog._novels = List.unmodifiable([
      for (final item in catalog._novels)
        if (item.id == novel.id) novel else item,
    ]);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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
      CatalogContentLevel.all => canAccessRestrictedContent() ? 0 : 1,
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

  static bool _usesAllCatalogSources(List<String> sources) {
    final selected = sources.toSet();
    return selected.length == catalogSourceValues.length &&
        selected.containsAll(catalogSourceValues);
  }
}
