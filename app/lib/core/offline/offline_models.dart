import '../model/reader_models.dart';

/// The retention contract for a locally stored chapter copy.
enum OfflineCopyKind {
  /// Opportunistic content that may be removed to satisfy the cache limit.
  cacheCopy,

  /// Reader-requested content that is retained until explicitly removed.
  offlineDownload,
}

enum DownloadTaskState {
  queued,
  fetching,
  validating,
  storing,
  paused,
  failed,
  stored,
  removed,
}

enum DownloadFailureKind {
  network,
  validation,
  insufficientStorage,
  unavailable,
  schema,
  unknown,
}

class ChapterRef {
  const ChapterRef({required this.novelId, required this.chapterId});

  final String novelId;
  final String chapterId;

  @override
  bool operator ==(Object other) {
    return other is ChapterRef &&
        other.novelId == novelId &&
        other.chapterId == chapterId;
  }

  @override
  int get hashCode => Object.hash(novelId, chapterId);
}

/// Metadata for a locally stored chapter revision.
///
/// A record always includes the Japanese original. [translationBytes] is null
/// while the requested [translationSource] is pending. Cache copies and
/// offline downloads deliberately use different records so their retention
/// rules cannot be confused by an eviction implementation.
class OfflineChapterCopy {
  OfflineChapterCopy({
    required this.id,
    required this.novelId,
    required this.chapterId,
    required this.kind,
    required this.translationSource,
    required this.originalBytes,
    required this.translationBytes,
    required this.storedAt,
    DateTime? lastReadAt,
    this.intentId,
    this.payloadId,
    this.revision,
    this.etag,
  }) : lastReadAt = lastReadAt ?? storedAt {
    if (id.isEmpty || novelId.isEmpty || chapterId.isEmpty) {
      throw ArgumentError('Copy, novel, and chapter IDs must be non-empty.');
    }
    if (payloadId?.isEmpty ?? false) {
      throw ArgumentError.value(payloadId, 'payloadId');
    }
    if (originalBytes < 0 ||
        (translationBytes != null && translationBytes! < 0)) {
      throw ArgumentError.value(
        totalBytes,
        'bytes',
        'Stored byte counts cannot be negative.',
      );
    }
    if (kind == OfflineCopyKind.cacheCopy && intentId != null) {
      throw ArgumentError('A Cache Copy cannot belong to a download intent.');
    }
    if (kind == OfflineCopyKind.offlineDownload && intentId == null) {
      throw ArgumentError('An Offline Download must belong to an intent.');
    }
  }

  final String id;
  final String novelId;
  final String chapterId;
  final OfflineCopyKind kind;
  final TranslationSource translationSource;
  final int originalBytes;
  final int? translationBytes;
  final DateTime storedAt;
  final DateTime lastReadAt;
  final String? intentId;
  final String? payloadId;
  final String? revision;
  final String? etag;

  ChapterRef get chapter => ChapterRef(novelId: novelId, chapterId: chapterId);
  bool get hasTranslation => translationBytes != null;
  int get totalBytes => originalBytes + (translationBytes ?? 0);

  OfflineChapterCopy touch(DateTime readAt) {
    return OfflineChapterCopy(
      id: id,
      novelId: novelId,
      chapterId: chapterId,
      kind: kind,
      translationSource: translationSource,
      originalBytes: originalBytes,
      translationBytes: translationBytes,
      storedAt: storedAt,
      lastReadAt: readAt,
      intentId: intentId,
      payloadId: payloadId,
      revision: revision,
      etag: etag,
    );
  }
}

/// Persistent desired state for reader-requested content.
sealed class DownloadIntent {
  const DownloadIntent({
    required this.id,
    required this.novelId,
    required this.translationSource,
    required this.createdAt,
    this.enabled = true,
  });

  final String id;
  final String novelId;
  final TranslationSource translationSource;
  final DateTime createdAt;
  final bool enabled;

  Iterable<String> targetChapterIds(Iterable<String> knownChapterIds);

  DownloadIntent withEnabled(bool enabled);
}

/// A fixed intent for one chapter. It never expands to future chapters.
final class ChapterDownloadIntent extends DownloadIntent {
  const ChapterDownloadIntent({
    required super.id,
    required super.novelId,
    required this.chapterId,
    required super.translationSource,
    required super.createdAt,
    super.enabled,
  });

  final String chapterId;

  @override
  Iterable<String> targetChapterIds(Iterable<String> knownChapterIds) {
    return enabled ? <String>[chapterId] : const <String>[];
  }

  @override
  ChapterDownloadIntent withEnabled(bool enabled) {
    return ChapterDownloadIntent(
      id: id,
      novelId: novelId,
      chapterId: chapterId,
      translationSource: translationSource,
      createdAt: createdAt,
      enabled: enabled,
    );
  }
}

/// An ongoing whole-novel intent that includes all future chapters while
/// enabled.
final class NovelDownloadIntent extends DownloadIntent {
  const NovelDownloadIntent({
    required super.id,
    required super.novelId,
    required super.translationSource,
    required super.createdAt,
    super.enabled,
  });

  @override
  Iterable<String> targetChapterIds(Iterable<String> knownChapterIds) sync* {
    if (!enabled) return;
    final seen = <String>{};
    for (final chapterId in knownChapterIds) {
      if (chapterId.isNotEmpty && seen.add(chapterId)) yield chapterId;
    }
  }

  @override
  NovelDownloadIntent withEnabled(bool enabled) {
    return NovelDownloadIntent(
      id: id,
      novelId: novelId,
      translationSource: translationSource,
      createdAt: createdAt,
      enabled: enabled,
    );
  }
}

class DownloadFailure {
  const DownloadFailure({
    required this.kind,
    required this.message,
    required this.retryable,
    this.requiredBytes,
    this.availableBytes,
  });

  factory DownloadFailure.insufficientStorage({
    required int requiredBytes,
    required int availableBytes,
  }) {
    return DownloadFailure(
      kind: DownloadFailureKind.insufficientStorage,
      message: 'Insufficient storage.',
      retryable: true,
      requiredBytes: requiredBytes,
      availableBytes: availableBytes,
    );
  }

  final DownloadFailureKind kind;
  final String message;
  final bool retryable;
  final int? requiredBytes;
  final int? availableBytes;
}

/// Immutable state machine for acquiring and atomically storing one chapter.
///
/// Each transition increases [revision], allowing a repository to reject stale
/// writers deterministically.
class DownloadTask {
  const DownloadTask._({
    required this.id,
    required this.intentId,
    required this.novelId,
    required this.chapterId,
    required this.translationSource,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    required this.attemptCount,
    required this.bytesReceived,
    this.totalBytes,
    this.failure,
    this.storedCopyId,
  });

  factory DownloadTask.queued({
    required String id,
    required String intentId,
    required String novelId,
    required String chapterId,
    required TranslationSource translationSource,
    required DateTime now,
  }) {
    if ([id, intentId, novelId, chapterId].any((value) => value.isEmpty)) {
      throw ArgumentError('Task and content IDs must be non-empty.');
    }
    return DownloadTask._(
      id: id,
      intentId: intentId,
      novelId: novelId,
      chapterId: chapterId,
      translationSource: translationSource,
      state: DownloadTaskState.queued,
      createdAt: now,
      updatedAt: now,
      revision: 0,
      attemptCount: 0,
      bytesReceived: 0,
    );
  }

  /// Rehydrates a task that was previously validated and stored locally.
  ///
  /// This is deliberately separate from state transitions: repositories may
  /// restore an exact revision, while ordinary callers must still move through
  /// the state machine one revision at a time.
  factory DownloadTask.restore({
    required String id,
    required String intentId,
    required String novelId,
    required String chapterId,
    required TranslationSource translationSource,
    required DownloadTaskState state,
    required DateTime createdAt,
    required DateTime updatedAt,
    required int revision,
    required int attemptCount,
    required int bytesReceived,
    int? totalBytes,
    DownloadFailure? failure,
    String? storedCopyId,
  }) {
    if ([id, intentId, novelId, chapterId].any((value) => value.isEmpty)) {
      throw ArgumentError('Task and content IDs must be non-empty.');
    }
    if (revision < 0 || attemptCount < 0 || bytesReceived < 0) {
      throw ArgumentError('Persisted task counters cannot be negative.');
    }
    if (totalBytes != null && (totalBytes < 0 || bytesReceived > totalBytes)) {
      throw ArgumentError('Persisted task byte counts are inconsistent.');
    }
    if (state == DownloadTaskState.failed && failure == null) {
      throw ArgumentError('A failed persisted task must retain its failure.');
    }
    if (state == DownloadTaskState.stored &&
        (storedCopyId == null || storedCopyId.isEmpty)) {
      throw ArgumentError('A stored persisted task must reference its copy.');
    }
    return DownloadTask._(
      id: id,
      intentId: intentId,
      novelId: novelId,
      chapterId: chapterId,
      translationSource: translationSource,
      state: state,
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: revision,
      attemptCount: attemptCount,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      failure: failure,
      storedCopyId: storedCopyId,
    );
  }

  final String id;
  final String intentId;
  final String novelId;
  final String chapterId;
  final TranslationSource translationSource;
  final DownloadTaskState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final int attemptCount;
  final int bytesReceived;
  final int? totalBytes;
  final DownloadFailure? failure;
  final String? storedCopyId;

  bool get isActive => const {
    DownloadTaskState.fetching,
    DownloadTaskState.validating,
    DownloadTaskState.storing,
  }.contains(state);

  DownloadTask beginFetching(DateTime now, {int? expectedBytes}) {
    _requireState({DownloadTaskState.queued}, 'begin fetching');
    if (expectedBytes != null && expectedBytes < bytesReceived) {
      throw ArgumentError.value(
        expectedBytes,
        'expectedBytes',
        'Expected bytes cannot be lower than received bytes.',
      );
    }
    return _next(
      state: DownloadTaskState.fetching,
      now: now,
      attemptCount: attemptCount + 1,
      totalBytes: expectedBytes ?? totalBytes,
    );
  }

  DownloadTask reportFetchProgress(
    DateTime now, {
    required int bytesReceived,
    int? totalBytes,
  }) {
    _requireState({DownloadTaskState.fetching}, 'report fetch progress');
    final resolvedTotal = totalBytes ?? this.totalBytes;
    if (bytesReceived < this.bytesReceived ||
        (resolvedTotal != null && bytesReceived > resolvedTotal)) {
      throw ArgumentError.value(
        bytesReceived,
        'bytesReceived',
        'Progress must be monotonic and cannot exceed the known total.',
      );
    }
    return _next(
      state: state,
      now: now,
      bytesReceived: bytesReceived,
      totalBytes: resolvedTotal,
    );
  }

  DownloadTask beginValidation(DateTime now) {
    _requireState({DownloadTaskState.fetching}, 'begin validation');
    return _next(state: DownloadTaskState.validating, now: now);
  }

  DownloadTask beginStoring(DateTime now) {
    _requireState({DownloadTaskState.validating}, 'begin storing');
    return _next(state: DownloadTaskState.storing, now: now);
  }

  DownloadTask markStored(DateTime now, {required String copyId}) {
    _requireState({DownloadTaskState.storing}, 'mark stored');
    if (copyId.isEmpty) throw ArgumentError.value(copyId, 'copyId');
    return _next(
      state: DownloadTaskState.stored,
      now: now,
      storedCopyId: copyId,
    );
  }

  DownloadTask pause(DateTime now) {
    _requireState({
      DownloadTaskState.queued,
      DownloadTaskState.fetching,
      DownloadTaskState.validating,
      DownloadTaskState.storing,
    }, 'pause');
    return _next(state: DownloadTaskState.paused, now: now);
  }

  DownloadTask resume(DateTime now) {
    _requireState({DownloadTaskState.paused}, 'resume');
    return _next(state: DownloadTaskState.queued, now: now);
  }

  DownloadTask fail(DateTime now, DownloadFailure failure) {
    _requireState({
      DownloadTaskState.fetching,
      DownloadTaskState.validating,
      DownloadTaskState.storing,
    }, 'fail');
    return _next(state: DownloadTaskState.failed, now: now, failure: failure);
  }

  DownloadTask retry(DateTime now) {
    _requireState({DownloadTaskState.failed}, 'retry');
    if (failure?.retryable != true) {
      throw StateError('Task $id has a permanent failure and cannot retry.');
    }
    return _next(state: DownloadTaskState.queued, now: now, clearFailure: true);
  }

  /// Restarts work that could not safely continue after an interrupted run.
  ///
  /// The current HTTP downloader fetches a whole chapter rather than resuming a
  /// byte range, so persisted transfer counters must not cross the restart.
  /// Repositories additionally require the owning intent to be enabled before
  /// applying this transition to a paused task.
  DownloadTask requeueForRestart(DateTime now) {
    final recoverableFailure =
        state == DownloadTaskState.failed && failure?.retryable == true;
    if (!isActive && state != DownloadTaskState.paused && !recoverableFailure) {
      throw StateError('Task $id cannot be restarted from ${state.name}.');
    }
    return DownloadTask._(
      id: id,
      intentId: intentId,
      novelId: novelId,
      chapterId: chapterId,
      translationSource: translationSource,
      state: DownloadTaskState.queued,
      createdAt: createdAt,
      updatedAt: now,
      revision: revision + 1,
      attemptCount: attemptCount,
      bytesReceived: 0,
    );
  }

  DownloadTask remove(DateTime now) {
    if (state == DownloadTaskState.removed) return this;
    return _next(
      state: DownloadTaskState.removed,
      now: now,
      clearFailure: true,
      clearStoredCopyId: true,
    );
  }

  void _requireState(Set<DownloadTaskState> allowed, String action) {
    if (!allowed.contains(state)) {
      throw StateError('Cannot $action task $id from ${state.name}.');
    }
  }

  DownloadTask _next({
    required DownloadTaskState state,
    required DateTime now,
    int? attemptCount,
    int? bytesReceived,
    int? totalBytes,
    DownloadFailure? failure,
    String? storedCopyId,
    bool clearFailure = false,
    bool clearStoredCopyId = false,
  }) {
    return DownloadTask._(
      id: id,
      intentId: intentId,
      novelId: novelId,
      chapterId: chapterId,
      translationSource: translationSource,
      state: state,
      createdAt: createdAt,
      updatedAt: now,
      revision: revision + 1,
      attemptCount: attemptCount ?? this.attemptCount,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      totalBytes: totalBytes ?? this.totalBytes,
      failure: clearFailure ? null : (failure ?? this.failure),
      storedCopyId: clearStoredCopyId
          ? null
          : (storedCopyId ?? this.storedCopyId),
    );
  }
}

class NovelStorageSummary {
  const NovelStorageSummary({
    required this.novelId,
    required this.cacheBytes,
    required this.offlineDownloadBytes,
    required this.cacheChapterCount,
    required this.offlineDownloadChapterCount,
    required this.translationSources,
  });

  final String novelId;
  final int cacheBytes;
  final int offlineDownloadBytes;
  final int cacheChapterCount;
  final int offlineDownloadChapterCount;
  final Set<TranslationSource> translationSources;
}

class OfflineStorageSummary {
  const OfflineStorageSummary({
    required this.cacheBytes,
    required this.offlineDownloadBytes,
    required this.cacheChapterCount,
    required this.offlineDownloadChapterCount,
    required this.perNovel,
  });

  factory OfflineStorageSummary.fromCopies(
    Iterable<OfflineChapterCopy> copies,
  ) {
    var cacheBytes = 0;
    var downloadBytes = 0;
    final cacheChapters = <ChapterRef>{};
    final downloadChapters = <ChapterRef>{};
    final groups = <String, List<OfflineChapterCopy>>{};

    for (final copy in copies) {
      groups.putIfAbsent(copy.novelId, () => []).add(copy);
      switch (copy.kind) {
        case OfflineCopyKind.cacheCopy:
          cacheBytes += copy.totalBytes;
          cacheChapters.add(copy.chapter);
        case OfflineCopyKind.offlineDownload:
          downloadBytes += copy.totalBytes;
          downloadChapters.add(copy.chapter);
      }
    }

    final novelIds = groups.keys.toList()..sort();
    final perNovel = <NovelStorageSummary>[
      for (final novelId in novelIds)
        _novelStorageSummary(novelId, groups[novelId]!),
    ];

    return OfflineStorageSummary(
      cacheBytes: cacheBytes,
      offlineDownloadBytes: downloadBytes,
      cacheChapterCount: cacheChapters.length,
      offlineDownloadChapterCount: downloadChapters.length,
      perNovel: List.unmodifiable(perNovel),
    );
  }

  final int cacheBytes;
  final int offlineDownloadBytes;
  final int cacheChapterCount;
  final int offlineDownloadChapterCount;
  final List<NovelStorageSummary> perNovel;

  int get totalBytes => cacheBytes + offlineDownloadBytes;

  static NovelStorageSummary _novelStorageSummary(
    String novelId,
    Iterable<OfflineChapterCopy> copies,
  ) {
    var cacheBytes = 0;
    var downloadBytes = 0;
    final cacheChapters = <ChapterRef>{};
    final downloadChapters = <ChapterRef>{};
    final sources = <TranslationSource>{};
    for (final copy in copies) {
      sources.add(copy.translationSource);
      switch (copy.kind) {
        case OfflineCopyKind.cacheCopy:
          cacheBytes += copy.totalBytes;
          cacheChapters.add(copy.chapter);
        case OfflineCopyKind.offlineDownload:
          downloadBytes += copy.totalBytes;
          downloadChapters.add(copy.chapter);
      }
    }
    return NovelStorageSummary(
      novelId: novelId,
      cacheBytes: cacheBytes,
      offlineDownloadBytes: downloadBytes,
      cacheChapterCount: cacheChapters.length,
      offlineDownloadChapterCount: downloadChapters.length,
      translationSources: Set.unmodifiable(sources),
    );
  }
}
