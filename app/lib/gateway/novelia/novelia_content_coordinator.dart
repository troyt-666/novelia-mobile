import '../../core/model/reader_models.dart';
import '../../core/offline/content_models.dart';
import '../../core/offline/content_repository.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_content_cache_adapter.dart';
import 'novelia_content_access.dart';
import 'novelia_domain_adapter.dart';
import 'novelia_gateway.dart';

enum NoveliaContentOrigin { live, cache }

class NoveliaContentResult<T> {
  const NoveliaContentResult._({
    required this.availability,
    required this.data,
    required this.origin,
    required this.failure,
  }) : assert(
         availability != CatalogAvailability.available || data != null,
         'Available content must contain data.',
       ),
       assert(origin == null || data != null, 'Only data can have an origin.');

  factory NoveliaContentResult.available(T data) {
    return NoveliaContentResult._(
      availability: CatalogAvailability.available,
      data: data,
      origin: NoveliaContentOrigin.live,
      failure: null,
    );
  }

  factory NoveliaContentResult.offline({
    T? cachedData,
    NoveliaGatewayException? failure,
  }) {
    return NoveliaContentResult._(
      availability: CatalogAvailability.offline,
      data: cachedData,
      origin: cachedData == null ? null : NoveliaContentOrigin.cache,
      failure: failure,
    );
  }

  factory NoveliaContentResult.authenticationRequired({
    T? cachedData,
    NoveliaGatewayException? failure,
  }) {
    return NoveliaContentResult._(
      availability: CatalogAvailability.authenticationRequired,
      data: cachedData,
      origin: cachedData == null ? null : NoveliaContentOrigin.cache,
      failure: failure,
    );
  }

  final CatalogAvailability availability;
  final T? data;
  final NoveliaContentOrigin? origin;
  final NoveliaGatewayException? failure;
}

class NoveliaCatalogSlice {
  const NoveliaCatalogSlice({
    required this.pageIndex,
    required this.totalPages,
    required this.novels,
  });

  /// Zero-based for catalog calls. Ranking calls use their declared page when
  /// present and otherwise use zero.
  final int pageIndex;
  final int totalPages;
  final List<CatalogNovel> novels;
}

abstract interface class NoveliaContentCoordinator {
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  );

  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  );

  Future<NoveliaContentResult<CatalogNovel>> loadDetails(CatalogNovel outline);

  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  });

  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  });
}

/// Optional synchronous cache boundary used by the reader to paint before a
/// live revalidation completes. Implementations must apply the same content
/// authorization rules as their live chapter path.
abstract interface class NoveliaChapterCacheReader {
  NovelChapter? cachedChapter(CatalogNovel novel, {required String chapterId});
}

typedef NoveliaClock = DateTime Function();

typedef NoveliaChapterCachedCallback =
    void Function({required String novelId, required String chapterId});

typedef NoveliaRestrictedContentAccess = bool Function();

/// Live-first orchestration with a normalized local-content fallback.
///
/// Catalog and detail operations never fetch chapter bodies. A chapter body is
/// fetched only through [loadChapter], where its payload and evictable Cache
/// Copy are stored atomically.
class LiveFirstNoveliaContentCoordinator
    implements NoveliaContentCoordinator, NoveliaChapterCacheReader {
  LiveFirstNoveliaContentCoordinator({
    required this.gateway,
    this.contentRepository,
    this.domainAdapter = const NoveliaDomainAdapter(),
    NoveliaContentCacheAdapter? cacheAdapter,
    NoveliaClock? clock,
    this.onChapterCached,
    this.canAccessRestrictedContent,
  }) : cacheAdapter =
           cacheAdapter ??
           NoveliaContentCacheAdapter(domainAdapter: domainAdapter),
       clock = clock ?? DateTime.now;

  final NoveliaGateway gateway;
  final ContentRepository? contentRepository;
  final NoveliaDomainAdapter domainAdapter;
  final NoveliaContentCacheAdapter cacheAdapter;
  final NoveliaClock clock;
  final NoveliaChapterCachedCallback? onChapterCached;
  final NoveliaRestrictedContentAccess? canAccessRestrictedContent;

  // Navigation provenance and later R18 revocation are separate facts.
  // A successful signed-in load can also verify an R18 novel.
  final Set<String> _verifiedNovelIds = <String>{};
  final Set<String> _revokedRestrictedNovelIds = <String>{};

  bool get _allowsRestrictedContent =>
      canAccessRestrictedContent?.call() == true;

  @override
  NovelChapter? cachedChapter(CatalogNovel novel, {required String chapterId}) {
    if (_isRestrictedNovel(novel)) return null;
    final key = domainAdapter.keyFromStableId(novel.id);
    final metadata = _chapterMetadata(novel, chapterId);
    if (key == null || metadata == null || !_hasVerifiedDetails(novel)) {
      return null;
    }
    return _cachedChapter(novel.id, chapterId);
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) async {
    _validateCatalogQuery(query);
    if (!_isSafeCatalogQuery(query)) {
      final failure = const NoveliaGatewayException(
        NoveliaGatewayFailureKind.forbidden,
        'Only the general-rated anonymous catalog is allowed.',
      );
      return NoveliaContentResult.authenticationRequired(
        cachedData: _cachedCatalog(query),
        failure: failure,
      );
    }

    try {
      final page = await gateway.listNovels(query);
      final novels = _mapAndCacheOutlines(page.items);
      return NoveliaContentResult.available(
        NoveliaCatalogSlice(
          pageIndex: query.page,
          totalPages: page.pageCount,
          novels: novels,
        ),
      );
    } on NoveliaGatewayException catch (failure) {
      return _catalogFailure(failure, query);
    } on NoveliaRestrictedContentException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Restricted content escaped the catalog filter.',
      );
    } on NoveliaDomainMappingException catch (failure) {
      throw _invalidMapping(failure);
    }
  }

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadRankings(
    NoveliaRankingQuery query,
  ) async {
    if (!defaultGeneralCatalogProviders.contains(query.providerId)) {
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'The ranking provider is not in the anonymous provider allowlist.',
        ),
      );
    }
    try {
      final page = await gateway.listRankings(query);
      final novels = _mapAndCacheOutlines(page.items);
      final declaredPage = int.tryParse(query.parameters['page'] ?? '1') ?? 1;
      return NoveliaContentResult.available(
        NoveliaCatalogSlice(
          pageIndex: declaredPage > 0 ? declaredPage - 1 : 0,
          totalPages: page.pageCount,
          novels: novels,
        ),
      );
    } on NoveliaGatewayException catch (failure) {
      // The content store does not retain ranking position or query identity.
      // Returning ordinary cached catalog rows as a ranking would be false.
      if (_isAuthenticationFailure(failure)) {
        return NoveliaContentResult.authenticationRequired(failure: failure);
      }
      if (_isAvailabilityFailure(failure)) {
        return NoveliaContentResult.offline(failure: failure);
      }
      rethrow;
    } on NoveliaDomainMappingException catch (failure) {
      throw _invalidMapping(failure);
    }
  }

  @override
  Future<NoveliaContentResult<CatalogNovel>> loadDetails(
    CatalogNovel outline,
  ) async {
    if (_rejectRestrictedNovel(outline)) {
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted novel details were rejected.',
        ),
      );
    }
    final key = domainAdapter.keyFromStableId(outline.id);
    if (key == null || !_hasVerifiedOutline(outline)) {
      return NoveliaContentResult.authenticationRequired(
        cachedData: _cachedDetails(outline.id),
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Novel details were not reached through verified general content.',
        ),
      );
    }

    try {
      final details = await gateway.getNovel(key);
      if (details.key != key) {
        throw const NoveliaDomainMappingException(
          'The detail response belongs to a different novel.',
        );
      }
      final novel = domainAdapter.mapDetails(
        details,
        allowRestricted: _allowsRestrictedContent,
      );
      if (_allowsRestrictedContent) {
        _revokedRestrictedNovelIds.remove(novel.id);
      }
      _verifiedNovelIds.add(novel.id);
      _bestEffortCacheDetails(novel);
      return NoveliaContentResult.available(novel);
    } on NoveliaRestrictedContentException {
      _revokeNovel(outline.id);
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted novel details were rejected.',
        ),
      );
    } on NoveliaGatewayException catch (failure) {
      return _contentFailure(failure, cachedData: _cachedDetails(outline.id));
    } on NoveliaDomainMappingException catch (failure) {
      throw _invalidMapping(failure);
    }
  }

  @override
  Future<NoveliaContentResult<NovelChapter>> loadChapter(
    CatalogNovel novel, {
    required String chapterId,
    TranslationSource cacheTranslationSource = TranslationSource.sakura,
  }) async {
    if (_rejectRestrictedNovel(novel)) {
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted chapter content was rejected.',
        ),
      );
    }
    final key = domainAdapter.keyFromStableId(novel.id);
    final metadata = _chapterMetadata(novel, chapterId);
    if (key == null || metadata == null || !_hasVerifiedDetails(novel)) {
      return NoveliaContentResult.authenticationRequired(
        cachedData: _cachedChapter(novel.id, chapterId),
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'The chapter is not in a verified general-content catalog.',
        ),
      );
    }

    try {
      final payload = await gateway.getChapter(key, chapterId);
      if (payload.key != key || payload.chapterId != chapterId) {
        throw const NoveliaDomainMappingException(
          'The chapter response does not match the request.',
        );
      }
      final chapter = domainAdapter.readerAdapter.buildSingleChapter(
        payload: payload,
        tocEntry: NoveliaTocEntry(
          japaneseTitle: metadata.japaneseTitle,
          chineseTitle: metadata.chineseTitle,
          chapterId: metadata.id,
          createdAt: metadata.publishedAt,
        ),
        index: metadata.index,
      );
      _bestEffortCacheChapter(
        payload,
        metadata: metadata,
        translationSource: cacheTranslationSource,
      );
      return NoveliaContentResult.available(chapter);
    } on NoveliaGatewayException catch (failure) {
      return _contentFailure(
        failure,
        cachedData: _cachedChapter(novel.id, chapterId),
      );
    } on NoveliaDomainMappingException catch (failure) {
      throw _invalidMapping(failure);
    }
  }

  @override
  Future<NoveliaContentResult<NoveliaCommentSlice>> loadComments(
    CatalogNovel novel, {
    int pageNumber = 1,
    int pageSize = 10,
  }) async {
    if (pageNumber < 1) {
      throw ArgumentError.value(pageNumber, 'pageNumber', 'Must be positive.');
    }
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be positive.');
    }
    if (_rejectRestrictedNovel(novel)) {
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted comments were rejected.',
        ),
      );
    }
    final key = domainAdapter.keyFromStableId(novel.id);
    if (key == null || !_hasVerifiedDetails(novel)) {
      return NoveliaContentResult.authenticationRequired(
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Comments require verified general-content novel details.',
        ),
      );
    }

    try {
      final page = await gateway.listComments(
        key,
        page: pageNumber - 1,
        pageSize: pageSize,
      );
      return NoveliaContentResult.available(
        domainAdapter.mapCommentPage(page, requestedPageNumber: pageNumber),
      );
    } on NoveliaGatewayException catch (failure) {
      // Comment bodies are not part of ContentRepository, so there is no
      // durable fallback to claim here.
      return _contentFailure<NoveliaCommentSlice>(failure);
    } on NoveliaDomainMappingException catch (failure) {
      throw _invalidMapping(failure);
    }
  }

  List<CatalogNovel> _mapAndCacheOutlines(
    Iterable<NoveliaNovelOutline> outlines,
  ) {
    final novels = <CatalogNovel>[];
    final cachedById = _cachedOutlinesById();
    for (final outline in outlines) {
      final novelId = outline.key.stableId;
      final previous = cachedById[novelId];
      final restricted =
          domainAdapter.isRestrictedAttentions(outline.attentions) ||
          (previous != null &&
              domainAdapter.isRestrictedAttentions(previous.tags));
      if (restricted) {
        if (!_allowsRestrictedContent) {
          _revokeNovel(novelId);
          continue;
        }
        _revokedRestrictedNovelIds.remove(novelId);
      }
      if (_isRevoked(novelId)) {
        continue;
      }
      final novel = domainAdapter.mapOutline(
        outline,
        allowRestricted: _allowsRestrictedContent,
      );
      novels.add(novel);
      _verifiedNovelIds.add(novel.id);
      _bestEffortCacheOutline(novel, previous: previous);
    }
    return List.unmodifiable(novels);
  }

  NoveliaContentResult<NoveliaCatalogSlice> _catalogFailure(
    NoveliaGatewayException failure,
    NoveliaCatalogQuery query,
  ) {
    final cached = _cachedCatalog(query);
    if (_isAuthenticationFailure(failure)) {
      return NoveliaContentResult.authenticationRequired(
        cachedData: cached,
        failure: failure,
      );
    }
    if (_isAvailabilityFailure(failure)) {
      return NoveliaContentResult.offline(cachedData: cached, failure: failure);
    }
    throw failure;
  }

  NoveliaContentResult<T> _contentFailure<T>(
    NoveliaGatewayException failure, {
    T? cachedData,
  }) {
    if (_isAuthenticationFailure(failure)) {
      return NoveliaContentResult.authenticationRequired(
        cachedData: cachedData,
        failure: failure,
      );
    }
    if (_isAvailabilityFailure(failure)) {
      return NoveliaContentResult.offline(
        cachedData: cachedData,
        failure: failure,
      );
    }
    throw failure;
  }

  bool _hasVerifiedOutline(CatalogNovel outline) {
    if (_verifiedNovelIds.contains(outline.id)) return true;
    final repository = contentRepository;
    if (repository == null) return false;
    try {
      final cached = repository.listCachedNovels().where(
        (candidate) => candidate.id == outline.id,
      );
      if (cached.isEmpty) return false;
      try {
        cacheAdapter.restoreOutline(
          cached.first,
          allowRestricted: _allowsRestrictedContent,
        );
      } on NoveliaRestrictedContentException {
        _revokeNovel(outline.id);
        return false;
      }
      _verifiedNovelIds.add(outline.id);
      return true;
    } on Object {
      return false;
    }
  }

  bool _hasVerifiedDetails(CatalogNovel novel) {
    if (!novel.hasChapterCatalog) return false;
    if (_verifiedNovelIds.contains(novel.id)) return true;
    return _cachedDetails(novel.id) != null;
  }

  NoveliaCatalogSlice? _cachedCatalog(NoveliaCatalogQuery query) {
    final repository = contentRepository;
    if (repository == null) return null;
    try {
      final normalizedSearch = query.search.trim().toLowerCase();
      final novels = <CatalogNovel>[];
      for (final cached in repository.listCachedNovels()) {
        try {
          if (_isRevoked(cached.id)) {
            continue;
          }
          final key = domainAdapter.keyFromStableId(cached.id);
          if (key == null || !query.providers.contains(key.providerId)) {
            continue;
          }
          final novel = cacheAdapter.restoreOutline(
            cached,
            allowRestricted: _allowsRestrictedContent,
          );
          final restricted = domainAdapter.isRestrictedCatalogNovel(novel);
          if (query.contentLevel == 1 && restricted) continue;
          if (query.contentLevel == 2 && !restricted) continue;
          if (!_matchesPublicationFilter(novel, query.publicationType) ||
              !_matchesTranslationFilter(novel, query.translationFilter)) {
            continue;
          }
          if (normalizedSearch.isNotEmpty &&
              ![
                novel.chineseTitle,
                novel.japaneseTitle,
                ?novel.author,
                ...novel.tags,
              ].any(
                (value) => value.toLowerCase().contains(normalizedSearch),
              )) {
            continue;
          }
          novels.add(novel);
          _verifiedNovelIds.add(novel.id);
        } on NoveliaRestrictedContentException {
          _revokeNovel(cached.id);
        } on NoveliaDomainMappingException {
          // A cached item that cannot be represented truthfully is omitted.
        }
      }
      int updatedOrder(CatalogNovel a, CatalogNovel b) {
        final aUpdated = a.updatedAt;
        final bUpdated = b.updatedAt;
        if (aUpdated == null && bUpdated == null) {
          return a.id.compareTo(b.id);
        }
        if (aUpdated == null) return 1;
        if (bUpdated == null) return -1;
        final dateOrder = bUpdated.compareTo(aUpdated);
        return dateOrder == 0 ? a.id.compareTo(b.id) : dateOrder;
      }

      switch (query.sort) {
        case 0:
          novels.sort(updatedOrder);
        case 1:
          // Cached outlines do not retain visit counts. Preserve repository
          // freshness order instead of inventing a local popularity rank.
          break;
        case 2:
          novels.sort((a, b) {
            final aStarts = a.chineseTitle.toLowerCase().startsWith(
              normalizedSearch,
            );
            final bStarts = b.chineseTitle.toLowerCase().startsWith(
              normalizedSearch,
            );
            if (aStarts != bStarts) return aStarts ? -1 : 1;
            return updatedOrder(a, b);
          });
      }
      final start = query.page * query.pageSize;
      final end = (start + query.pageSize).clamp(0, novels.length);
      final pageNovels = start >= novels.length
          ? const <CatalogNovel>[]
          : novels.sublist(start, end);
      final pageCount = novels.isEmpty
          ? 0
          : (novels.length + query.pageSize - 1) ~/ query.pageSize;
      return NoveliaCatalogSlice(
        pageIndex: query.page,
        totalPages: pageCount,
        novels: List.unmodifiable(pageNovels),
      );
    } on Object {
      return null;
    }
  }

  CatalogNovel? _cachedDetails(String novelId) {
    if (_isRevoked(novelId)) {
      return null;
    }
    final repository = contentRepository;
    if (repository == null) return null;
    try {
      final detail = repository.novelDetail(novelId);
      if (detail == null) return null;
      late final CatalogNovel novel;
      try {
        novel = cacheAdapter.restoreDetails(
          detail,
          allowRestricted: _allowsRestrictedContent,
        );
      } on NoveliaRestrictedContentException {
        _revokeNovel(novelId);
        return null;
      }
      _verifiedNovelIds.add(novel.id);
      return novel;
    } on Object {
      return null;
    }
  }

  NovelChapter? _cachedChapter(String novelId, String chapterId) {
    if (_isRevoked(novelId)) {
      return null;
    }
    final repository = contentRepository;
    if (repository == null) return null;
    try {
      final payload = repository.chapterPayload(
        novelId: novelId,
        chapterId: chapterId,
      );
      return payload == null ? null : cacheAdapter.restoreChapter(payload);
    } on Object {
      return null;
    }
  }

  Map<String, CachedNovelOutline> _cachedOutlinesById() {
    final repository = contentRepository;
    if (repository == null) return const {};
    try {
      return {
        for (final outline in repository.listCachedNovels())
          outline.id: outline,
      };
    } on Object {
      return const {};
    }
  }

  void _bestEffortCacheOutline(
    CatalogNovel outline, {
    CachedNovelOutline? previous,
  }) {
    final repository = contentRepository;
    if (repository == null || _isRevoked(outline.id)) {
      return;
    }
    try {
      var cached = cacheAdapter.cacheOutline(outline, fetchedAt: clock());
      if (previous != null) {
        cached = cacheAdapter.preserveDetailOnlyOutlineFields(
          cached,
          from: previous,
        );
      }
      repository.upsertNovelOutline(cached);
    } on Object {
      // A local cache failure does not invalidate an otherwise valid live read.
    }
  }

  void _bestEffortCacheDetails(CatalogNovel details) {
    final repository = contentRepository;
    if (repository == null || _isRevoked(details.id)) {
      return;
    }
    try {
      repository.upsertNovelDetail(
        cacheAdapter.cacheDetails(details, fetchedAt: clock()),
      );
    } on Object {
      // A local cache failure does not invalidate an otherwise valid live read.
    }
  }

  void _bestEffortCacheChapter(
    NoveliaChapterPayload payload, {
    required NovelChapter metadata,
    required TranslationSource translationSource,
  }) {
    final repository = contentRepository;
    if (repository == null) return;
    try {
      final fetchedAt = clock();
      final cachedPayload = cacheAdapter.cacheChapter(
        payload,
        metadata: metadata,
        fetchedAt: fetchedAt,
      );
      repository.cacheChapterPayload(
        payload: cachedPayload,
        copy: cacheAdapter.cacheCopy(
          cachedPayload,
          translationSource: translationSource,
          storedAt: fetchedAt,
        ),
      );
      onChapterCached?.call(
        novelId: payload.key.stableId,
        chapterId: payload.chapterId,
      );
    } on Object {
      // Atomic storage either succeeds together or leaves the live result alone.
    }
  }

  static NovelChapter? _chapterMetadata(CatalogNovel novel, String chapterId) {
    final chapters = novel.readerNovel?.chapters;
    if (chapters == null) return null;
    for (final chapter in chapters) {
      if (chapter.id == chapterId) return chapter;
    }
    return null;
  }

  void _revokeNovel(String novelId) {
    _verifiedNovelIds.remove(novelId);
    _revokedRestrictedNovelIds.add(novelId);
    final repository = contentRepository;
    if (repository == null) return;
    revokeRestrictedNovelCache(
      repository,
      novelId: novelId,
      checkedAt: clock(),
      domainAdapter: domainAdapter,
    );
  }

  bool _isRevoked(String novelId) =>
      !_allowsRestrictedContent && _revokedRestrictedNovelIds.contains(novelId);

  bool _isRestrictedNovel(CatalogNovel novel) =>
      !_allowsRestrictedContent &&
      (_revokedRestrictedNovelIds.contains(novel.id) ||
          domainAdapter.isRestrictedCatalogNovel(novel));

  bool _rejectRestrictedNovel(CatalogNovel novel) {
    if (!_isRestrictedNovel(novel)) return false;
    if (!_revokedRestrictedNovelIds.contains(novel.id)) {
      _revokeNovel(novel.id);
    }
    return true;
  }

  bool _isSafeCatalogQuery(NoveliaCatalogQuery query) {
    final allowedLevel =
        query.contentLevel == 1 ||
        (_allowsRestrictedContent &&
            (query.contentLevel == 0 || query.contentLevel == 2));
    return allowedLevel &&
        query.providers.every(defaultGeneralCatalogProviders.contains);
  }

  static void _validateCatalogQuery(NoveliaCatalogQuery query) {
    if (query.page < 0) {
      throw ArgumentError.value(query.page, 'query.page');
    }
    if (query.pageSize <= 0) {
      throw ArgumentError.value(query.pageSize, 'query.pageSize');
    }
    if (query.publicationType < 0 || query.publicationType > 3) {
      throw ArgumentError.value(query.publicationType, 'query.publicationType');
    }
    if (query.contentLevel < 0 || query.contentLevel > 2) {
      throw ArgumentError.value(query.contentLevel, 'query.contentLevel');
    }
    if (query.translationFilter < 0 || query.translationFilter > 2) {
      throw ArgumentError.value(
        query.translationFilter,
        'query.translationFilter',
      );
    }
    if (query.sort < 0 || query.sort > 2) {
      throw ArgumentError.value(query.sort, 'query.sort');
    }
  }

  static bool _matchesPublicationFilter(CatalogNovel novel, int filter) {
    return switch (filter) {
      0 => true,
      1 => novel.publicationState == NovelPublicationState.ongoing,
      2 => novel.publicationState == NovelPublicationState.completed,
      3 => novel.publicationState == NovelPublicationState.shortStory,
      _ => false,
    };
  }

  static bool _matchesTranslationFilter(CatalogNovel novel, int filter) {
    return switch (filter) {
      0 => true,
      1 =>
        novel.coverageFor(TranslationSource.gpt.label)?.hasTranslation == true,
      2 =>
        novel.coverageFor(TranslationSource.sakura.label)?.hasTranslation ==
            true,
      _ => false,
    };
  }

  static bool _isAuthenticationFailure(NoveliaGatewayException failure) {
    return failure.kind == NoveliaGatewayFailureKind.authenticationRequired ||
        failure.kind == NoveliaGatewayFailureKind.forbidden;
  }

  static bool _isAvailabilityFailure(NoveliaGatewayException failure) {
    return failure.kind == NoveliaGatewayFailureKind.network ||
        failure.kind == NoveliaGatewayFailureKind.timeout ||
        failure.kind == NoveliaGatewayFailureKind.server;
  }

  static NoveliaGatewayException _invalidMapping(
    NoveliaDomainMappingException failure,
  ) {
    return NoveliaGatewayException(
      NoveliaGatewayFailureKind.invalidResponse,
      failure.message,
    );
  }
}
