import 'dart:convert';

import '../../core/model/reader_models.dart';
import '../../core/offline/content_models.dart';
import '../../core/offline/content_repository.dart';
import '../../core/offline/offline_models.dart';
import '../../core/offline/offline_repository.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_content_cache_adapter.dart';
import 'novelia_content_coordinator.dart';
import 'novelia_domain_adapter.dart';
import 'novelia_gateway.dart';

class NoveliaDownloadRun {
  const NoveliaDownloadRun({
    required this.intentId,
    required this.availability,
    required this.usedCachedToc,
    required this.knownChapterCount,
    required this.createdTaskCount,
    required this.refreshedCopyCount,
    required this.refreshFailureCount,
    required this.tasks,
    this.failure,
  });

  final String intentId;
  final CatalogAvailability availability;
  final bool usedCachedToc;
  final int knownChapterCount;
  final int createdTaskCount;
  final int refreshedCopyCount;
  final int refreshFailureCount;
  final List<DownloadTask> tasks;
  final NoveliaGatewayException? failure;
}

abstract interface class NoveliaDownloadCoordinator {
  /// Explicitly hydrates one intent's TOC, reconciles it, and processes queued
  /// tasks. Calling this method is the only path that performs eager chapter
  /// fetching for a download intent.
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId);
}

/// Drives the offline state machine while keeping gateway DTOs out of storage.
///
/// [contentRepository] and [offlineRepository] must be views of the same
/// transactional store in production. `commitDownloadedChapter` atomically
/// writes the payload, protected copy, and final task transition.
class AsyncNoveliaDownloadCoordinator implements NoveliaDownloadCoordinator {
  AsyncNoveliaDownloadCoordinator({
    required this.gateway,
    required this.contentRepository,
    required this.offlineRepository,
    this.domainAdapter = const NoveliaDomainAdapter(),
    NoveliaContentCacheAdapter? cacheAdapter,
    NoveliaClock? clock,
    this.maximumStoredRefreshesPerRun = 20,
    this.canAccessRestrictedContent,
  }) : cacheAdapter =
           cacheAdapter ??
           NoveliaContentCacheAdapter(domainAdapter: domainAdapter),
       clock = clock ?? DateTime.now,
       assert(
         maximumStoredRefreshesPerRun > 0,
         'maximumStoredRefreshesPerRun must be positive.',
       );

  final NoveliaGateway gateway;
  final ContentRepository contentRepository;
  final OfflineRepository offlineRepository;
  final NoveliaDomainAdapter domainAdapter;
  final NoveliaContentCacheAdapter cacheAdapter;
  final NoveliaClock clock;
  final int maximumStoredRefreshesPerRun;
  final NoveliaRestrictedContentAccess? canAccessRestrictedContent;
  final Map<String, String> _storedRefreshCursorByIntent = <String, String>{};

  bool get _allowsRestrictedContent =>
      canAccessRestrictedContent?.call() == true;

  @override
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId) async {
    final intent = offlineRepository.intentById(intentId);
    if (intent == null) {
      throw StateError('Unknown Novelia download intent $intentId.');
    }
    if (!_allowsRestrictedContent && _hasRestrictedMarker(intent.novelId)) {
      return _runResult(
        intentId: intentId,
        availability: CatalogAvailability.authenticationRequired,
        usedCachedToc: false,
        knownChapterCount: 0,
        createdTaskCount: 0,
        failure: const NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted content cannot be downloaded anonymously.',
        ),
      );
    }

    final hydration = await _hydrateToc(intent.novelId);
    final novel = hydration.novel;
    if (novel == null) {
      return _runResult(
        intentId: intentId,
        availability: hydration.availability,
        usedCachedToc: false,
        knownChapterCount: 0,
        createdTaskCount: 0,
        failure: hydration.failure,
      );
    }

    final knownChapterIds = [
      for (final chapter in novel.readerNovel!.chapters) chapter.id,
    ];
    final created = offlineRepository.reconcileIntent(
      intentId: intentId,
      knownChapterIds: knownChapterIds,
      now: clock(),
    );
    final refreshCandidates = _rotatingRefreshBatch(intentId);

    if (hydration.availability != CatalogAvailability.available ||
        !intent.enabled) {
      return _runResult(
        intentId: intentId,
        availability: hydration.availability,
        usedCachedToc: hydration.usedCache,
        knownChapterCount: knownChapterIds.length,
        createdTaskCount: created.length,
        failure: hydration.failure,
      );
    }

    final metadataById = {
      for (final chapter in novel.readerNovel!.chapters) chapter.id: chapter,
    };
    final queuedTasks = offlineRepository
        .listTasks(intentId: intentId)
        .where((task) => task.state == DownloadTaskState.queued)
        .toList(growable: false);
    for (final task in queuedTasks) {
      await _processTask(task, metadataById[task.chapterId]);
    }

    var refreshedCopyCount = 0;
    var refreshFailureCount = 0;
    for (final candidate in refreshCandidates) {
      final refreshed = await _refreshStoredCopy(
        candidate,
        metadataById[candidate.task.chapterId],
      );
      if (refreshed) {
        refreshedCopyCount += 1;
      } else {
        refreshFailureCount += 1;
      }
    }

    return _runResult(
      intentId: intentId,
      availability: CatalogAvailability.available,
      usedCachedToc: false,
      knownChapterCount: knownChapterIds.length,
      createdTaskCount: created.length,
      refreshedCopyCount: refreshedCopyCount,
      refreshFailureCount: refreshFailureCount,
    );
  }

  Iterable<_StoredRefreshCandidate> _refreshCandidates(String intentId) sync* {
    for (final task in offlineRepository.listTasks(intentId: intentId)) {
      if (task.state != DownloadTaskState.stored || task.storedCopyId == null) {
        continue;
      }
      final copy = offlineRepository.copyById(task.storedCopyId!);
      if (copy == null ||
          copy.kind != OfflineCopyKind.offlineDownload ||
          copy.translationBytes != null ||
          copy.payloadId == null) {
        continue;
      }
      final payload = contentRepository.chapterPayloadById(copy.payloadId!);
      final translation = payload?.translationFor(task.translationSource);
      if (translation?.availability != TranslationAvailability.pending &&
          translation?.availability != TranslationAvailability.invalid) {
        continue;
      }
      yield _StoredRefreshCandidate(task: task, copy: copy);
    }
  }

  List<_StoredRefreshCandidate> _rotatingRefreshBatch(String intentId) {
    final candidates = _refreshCandidates(intentId).toList()
      ..sort((a, b) => a.task.id.compareTo(b.task.id));
    if (candidates.isEmpty) {
      _storedRefreshCursorByIntent.remove(intentId);
      return const [];
    }

    final previousTaskId = _storedRefreshCursorByIntent[intentId];
    var start = 0;
    if (previousTaskId != null) {
      final previousIndex = candidates.indexWhere(
        (candidate) => candidate.task.id == previousTaskId,
      );
      if (previousIndex >= 0) {
        start = (previousIndex + 1) % candidates.length;
      } else {
        final nextIndex = candidates.indexWhere(
          (candidate) => candidate.task.id.compareTo(previousTaskId) > 0,
        );
        start = nextIndex < 0 ? 0 : nextIndex;
      }
    }

    final count = maximumStoredRefreshesPerRun.clamp(0, candidates.length);
    final batch = <_StoredRefreshCandidate>[
      for (var offset = 0; offset < count; offset++)
        candidates[(start + offset) % candidates.length],
    ];
    _storedRefreshCursorByIntent[intentId] = batch.last.task.id;
    return List.unmodifiable(batch);
  }

  Future<bool> _refreshStoredCopy(
    _StoredRefreshCandidate candidate,
    NovelChapter? metadata,
  ) async {
    if (metadata == null) return false;
    final key = domainAdapter.keyFromStableId(candidate.task.novelId);
    if (key == null) return false;

    NoveliaChapterPayload response;
    try {
      response = await gateway.getChapter(key, candidate.task.chapterId);
    } on NoveliaGatewayException {
      return false;
    }
    if (response.key != key || response.chapterId != candidate.task.chapterId) {
      return false;
    }

    try {
      final refreshedAt = clock();
      final payload = cacheAdapter.cacheChapter(
        response,
        metadata: metadata,
        fetchedAt: refreshedAt,
      );
      final copy = cacheAdapter.refreshedDownloadedCopy(
        payload,
        existingCopy: candidate.copy,
        refreshedAt: refreshedAt,
      );
      contentRepository.refreshDownloadedChapter(
        taskId: candidate.task.id,
        payload: payload,
        copy: copy,
      );
      final storedTask = offlineRepository.taskById(candidate.task.id);
      return storedTask?.state == DownloadTaskState.stored &&
          storedTask?.storedCopyId == copy.id;
    } on Object {
      return false;
    }
  }

  Future<_TocHydration> _hydrateToc(String novelId) async {
    final key = domainAdapter.keyFromStableId(novelId);
    if (key == null) {
      return const _TocHydration(
        availability: CatalogAvailability.authenticationRequired,
        failure: NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'The download intent does not target an allowed Novelia novel.',
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
      try {
        contentRepository.upsertNovelDetail(
          cacheAdapter.cacheDetails(
            details,
            fetchedAt: clock(),
            allowRestricted: _allowsRestrictedContent,
          ),
        );
      } on Object {
        // Downloading may continue with verified live metadata. The final
        // payload commit remains atomic and is not best-effort.
      }
      return _TocHydration(
        availability: CatalogAvailability.available,
        novel: novel,
      );
    } on NoveliaRestrictedContentException {
      _markCachedNovelRestricted(novelId);
      return const _TocHydration(
        availability: CatalogAvailability.authenticationRequired,
        failure: NoveliaGatewayException(
          NoveliaGatewayFailureKind.forbidden,
          'Restricted content cannot be downloaded anonymously.',
        ),
      );
    } on NoveliaGatewayException catch (failure) {
      if (!_isAuthenticationFailure(failure) &&
          !_isAvailabilityFailure(failure)) {
        rethrow;
      }
      final cached = _cachedDetails(novelId);
      return _TocHydration(
        availability: _isAuthenticationFailure(failure)
            ? CatalogAvailability.authenticationRequired
            : CatalogAvailability.offline,
        novel: cached,
        usedCache: cached != null,
        failure: failure,
      );
    } on NoveliaDomainMappingException catch (failure) {
      throw NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        failure.message,
      );
    }
  }

  Future<void> _processTask(
    DownloadTask initialTask,
    NovelChapter? metadata,
  ) async {
    var task = initialTask.beginFetching(clock());
    offlineRepository.saveTask(task);

    if (metadata == null) {
      _saveFailure(
        task,
        const DownloadFailure(
          kind: DownloadFailureKind.unavailable,
          message: 'The requested chapter is absent from the current TOC.',
          retryable: false,
        ),
      );
      return;
    }

    final key = domainAdapter.keyFromStableId(task.novelId);
    if (key == null) {
      _saveFailure(
        task,
        const DownloadFailure(
          kind: DownloadFailureKind.validation,
          message: 'The task has an invalid Novelia novel ID.',
          retryable: false,
        ),
      );
      return;
    }

    NoveliaChapterPayload response;
    try {
      response = await gateway.getChapter(key, task.chapterId);
    } on NoveliaGatewayException catch (failure) {
      _saveFailure(task, _downloadFailure(failure));
      return;
    }

    if (response.key != key || response.chapterId != task.chapterId) {
      task = task.beginValidation(clock());
      offlineRepository.saveTask(task);
      _saveFailure(
        task,
        const DownloadFailure(
          kind: DownloadFailureKind.validation,
          message: 'The fetched chapter identity did not match the task.',
          retryable: false,
        ),
      );
      return;
    }

    CachedChapterPayload payload;
    try {
      payload = cacheAdapter.cacheChapter(
        response,
        metadata: metadata,
        fetchedAt: clock(),
      );
    } on NoveliaDomainMappingException catch (failure) {
      task = task.beginValidation(clock());
      offlineRepository.saveTask(task);
      _saveFailure(
        task,
        DownloadFailure(
          kind: DownloadFailureKind.validation,
          message: failure.message,
          retryable: false,
        ),
      );
      return;
    }

    final selected = payload.translationFor(task.translationSource)!;
    final fetchedBytes =
        _utf8Length(payload.japaneseBlocks) +
        (selected.availability == TranslationAvailability.complete
            ? _utf8Length(selected.blocks)
            : 0);
    task = task.reportFetchProgress(
      clock(),
      bytesReceived: fetchedBytes,
      totalBytes: fetchedBytes,
    );
    offlineRepository.saveTask(task);
    task = task.beginValidation(clock());
    offlineRepository.saveTask(task);

    if (selected.availability == TranslationAvailability.invalid) {
      _saveFailure(
        task,
        const DownloadFailure(
          kind: DownloadFailureKind.validation,
          message:
              'The selected translation did not align with the Japanese source.',
          retryable: false,
        ),
      );
      return;
    }

    // Pending is valid offline data: the protected copy contains the exact
    // Japanese blocks and a null translation byte count.
    task = task.beginStoring(clock());
    offlineRepository.saveTask(task);
    final storedAt = clock();
    final copy = cacheAdapter.downloadedCopy(
      payload,
      task: task,
      storedAt: storedAt,
    );
    try {
      contentRepository.commitDownloadedChapter(
        taskId: task.id,
        payload: payload,
        copy: copy,
        now: storedAt,
      );
      final committed = offlineRepository.taskById(task.id);
      if (committed?.state != DownloadTaskState.stored) {
        throw StateError(
          'ContentRepository and OfflineRepository must share one transaction.',
        );
      }
    } on Object {
      final current = offlineRepository.taskById(task.id);
      if (current?.state == DownloadTaskState.storing) {
        _saveFailure(
          current!,
          const DownloadFailure(
            kind: DownloadFailureKind.unknown,
            message: 'The downloaded chapter could not be stored atomically.',
            retryable: true,
          ),
        );
      }
    }
  }

  CatalogNovel? _cachedDetails(String novelId) {
    try {
      final detail = contentRepository.novelDetail(novelId);
      return detail == null
          ? null
          : cacheAdapter.restoreDetails(
              detail,
              allowRestricted: _allowsRestrictedContent,
            );
    } on Object {
      return null;
    }
  }

  bool _hasRestrictedMarker(String novelId) {
    try {
      return contentRepository.listCachedNovels().any(
        (outline) =>
            outline.id == novelId &&
            domainAdapter.isRestrictedAttentions(outline.tags),
      );
    } on Object {
      return false;
    }
  }

  void _markCachedNovelRestricted(String novelId) {
    try {
      final cached = contentRepository.listCachedNovels().where(
        (outline) => outline.id == novelId,
      );
      if (cached.isNotEmpty &&
          !domainAdapter.isRestrictedAttentions(cached.first.tags)) {
        final outline = cached.first;
        contentRepository.upsertNovelOutline(
          CachedNovelOutline(
            id: outline.id,
            chineseTitle: outline.chineseTitle,
            japaneseTitle: outline.japaneseTitle,
            author: outline.author,
            contentSource: outline.contentSource,
            publicationState: outline.publicationState,
            chapterCount: outline.chapterCount,
            wordCount: outline.wordCount,
            updatedAt: outline.updatedAt,
            tags: [...outline.tags, 'R18'],
            translationCoverage: outline.translationCoverage,
            fetchedAt: clock(),
            revision: outline.revision,
            etag: outline.etag,
          ),
        );
      }
      contentRepository.removeCachedNovel(novelId);
    } on Object {
      // The current synchronization still fails closed if cleanup is damaged.
    }
  }

  void _saveFailure(DownloadTask task, DownloadFailure failure) {
    offlineRepository.saveTask(task.fail(clock(), failure));
  }

  NoveliaDownloadRun _runResult({
    required String intentId,
    required CatalogAvailability availability,
    required bool usedCachedToc,
    required int knownChapterCount,
    required int createdTaskCount,
    int refreshedCopyCount = 0,
    int refreshFailureCount = 0,
    NoveliaGatewayException? failure,
  }) {
    return NoveliaDownloadRun(
      intentId: intentId,
      availability: availability,
      usedCachedToc: usedCachedToc,
      knownChapterCount: knownChapterCount,
      createdTaskCount: createdTaskCount,
      refreshedCopyCount: refreshedCopyCount,
      refreshFailureCount: refreshFailureCount,
      tasks: offlineRepository.listTasks(intentId: intentId),
      failure: failure,
    );
  }

  static DownloadFailure _downloadFailure(NoveliaGatewayException failure) {
    return switch (failure.kind) {
      NoveliaGatewayFailureKind.network ||
      NoveliaGatewayFailureKind.timeout ||
      NoveliaGatewayFailureKind.server => const DownloadFailure(
        kind: DownloadFailureKind.network,
        message: 'The chapter could not be downloaded.',
        retryable: true,
      ),
      NoveliaGatewayFailureKind.authenticationRequired ||
      NoveliaGatewayFailureKind.forbidden => const DownloadFailure(
        kind: DownloadFailureKind.unavailable,
        message: 'The chapter requires authorization.',
        retryable: true,
      ),
      NoveliaGatewayFailureKind.notFound => const DownloadFailure(
        kind: DownloadFailureKind.unavailable,
        message: 'The chapter is no longer available.',
        retryable: false,
      ),
      NoveliaGatewayFailureKind.invalidResponse => const DownloadFailure(
        kind: DownloadFailureKind.schema,
        message: 'The chapter response was not understood.',
        retryable: false,
      ),
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

  static int _utf8Length(Iterable<String> blocks) {
    return blocks.fold<int>(
      0,
      (total, block) => total + utf8.encode(block).length,
    );
  }
}

class _TocHydration {
  const _TocHydration({
    required this.availability,
    this.novel,
    this.usedCache = false,
    this.failure,
  });

  final CatalogAvailability availability;
  final CatalogNovel? novel;
  final bool usedCache;
  final NoveliaGatewayException? failure;
}

class _StoredRefreshCandidate {
  const _StoredRefreshCandidate({required this.task, required this.copy});

  final DownloadTask task;
  final OfflineChapterCopy copy;
}
