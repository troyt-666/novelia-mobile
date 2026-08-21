import 'content_models.dart';
import 'content_repository.dart';
import 'offline_models.dart';

abstract interface class DownloadIntentRepository {
  void saveIntent(DownloadIntent intent);

  DownloadIntent? intentById(String id);

  List<DownloadIntent> listIntents();

  List<DownloadTask> reconcileIntent({
    required String intentId,
    required Iterable<String> knownChapterIds,
    required DateTime now,
  });

  /// Atomically restarts interrupted work for one enabled intent.
  ///
  /// Active tasks, retryable failures, and paused tasks whose intent remains
  /// enabled are returned to a clean queue state. Deliberately paused intents
  /// and permanent failures are left untouched.
  List<DownloadTask> requeueInterruptedTasks({
    required String intentId,
    required DateTime now,
  });

  void pauseIntent(String intentId, DateTime now);

  void resumeIntent(String intentId, DateTime now);

  OfflineRemovalSummary removeIntent(String intentId, DateTime now);
}

abstract interface class DownloadTaskRepository {
  DownloadTask? taskById(String id);

  List<DownloadTask> listTasks({String? intentId, String? novelId});

  void saveTask(DownloadTask task);

  OfflineChapterCopy commitStoredTask({
    required String taskId,
    required OfflineChapterCopy copy,
    required DateTime now,
  });

  DownloadProgressSummary progressSummary({String? intentId});

  List<NovelDownloadProgressSummary> progressByNovel();
}

abstract interface class OfflineContentRepository {
  OfflineChapterCopy? copyById(String id);

  List<OfflineChapterCopy> listCopies({String? novelId, OfflineCopyKind? kind});

  void saveCopy(OfflineChapterCopy copy);

  void touchCopy(String id, DateTime readAt);

  List<OfflineChapterCopy> evictCacheTo({
    required int maxBytes,
    Set<ChapterRef> protectedChapters,
  });

  OfflineStorageSummary storageSummary();
}

abstract interface class OfflineRepository
    implements
        DownloadIntentRepository,
        DownloadTaskRepository,
        OfflineContentRepository {}

/// Deterministic repository used by fixtures, unit tests, and UI development.
///
/// It deliberately mirrors database boundaries without pretending to persist
/// across process restarts. A later SQLite implementation can implement the
/// same interfaces.
class InMemoryOfflineRepository
    implements OfflineRepository, ContentRepository {
  final Map<String, DownloadIntent> _intents = {};
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, OfflineChapterCopy> _copies = {};
  final Map<String, CachedNovelOutline> _outlines = {};
  final Map<String, CachedNovelDetail> _details = {};
  final Map<String, CachedChapterPayload> _payloads = {};

  @override
  void saveIntent(DownloadIntent intent) {
    if (intent.id.isEmpty || intent.novelId.isEmpty) {
      throw ArgumentError('Intent and novel IDs must be non-empty.');
    }
    _intents[intent.id] = intent;
  }

  @override
  DownloadIntent? intentById(String id) => _intents[id];

  @override
  List<DownloadIntent> listIntents() {
    final values = _intents.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(values);
  }

  @override
  List<DownloadTask> reconcileIntent({
    required String intentId,
    required Iterable<String> knownChapterIds,
    required DateTime now,
  }) {
    final intent = _requireIntent(intentId);
    final created = <DownloadTask>[];
    for (final chapterId in intent.targetChapterIds(knownChapterIds)) {
      final taskId = _taskId(
        intentId: intent.id,
        chapterId: chapterId,
        sourceName: intent.translationSource.name,
      );
      if (_tasks.containsKey(taskId)) continue;
      final task = DownloadTask.queued(
        id: taskId,
        intentId: intent.id,
        novelId: intent.novelId,
        chapterId: chapterId,
        translationSource: intent.translationSource,
        now: now,
      );
      _tasks[task.id] = task;
      created.add(task);
    }
    return List.unmodifiable(created);
  }

  @override
  List<DownloadTask> requeueInterruptedTasks({
    required String intentId,
    required DateTime now,
  }) {
    final intent = _requireIntent(intentId);
    if (!intent.enabled) return const [];
    final replacements = <DownloadTask>[
      for (final task in listTasks(intentId: intentId))
        if (task.isActive ||
            task.state == DownloadTaskState.paused ||
            (task.state == DownloadTaskState.failed &&
                task.failure?.retryable == true))
          task.requeueForRestart(now),
    ];

    // Construct every transition before mutating the maps, mirroring a single
    // database transaction for the deterministic in-memory adapter.
    for (final task in replacements) {
      _tasks[task.id] = task;
    }
    return List.unmodifiable(replacements);
  }

  @override
  void pauseIntent(String intentId, DateTime now) {
    final intent = _requireIntent(intentId);
    _intents[intentId] = intent.withEnabled(false);
    for (final task in listTasks(intentId: intentId)) {
      if (task.state == DownloadTaskState.queued || task.isActive) {
        saveTask(task.pause(now));
      }
    }
  }

  @override
  void resumeIntent(String intentId, DateTime now) {
    final intent = _requireIntent(intentId);
    _intents[intentId] = intent.withEnabled(true);
    for (final task in listTasks(intentId: intentId)) {
      if (task.state == DownloadTaskState.paused) {
        saveTask(task.resume(now));
      }
    }
  }

  @override
  OfflineRemovalSummary removeIntent(String intentId, DateTime now) {
    _requireIntent(intentId);
    _intents.remove(intentId);

    var removedTasks = 0;
    for (final task in listTasks(intentId: intentId)) {
      if (task.state != DownloadTaskState.removed) {
        _tasks[task.id] = task.remove(now);
        removedTasks += 1;
      }
    }

    final copyIds = _copies.values
        .where(
          (copy) =>
              copy.kind == OfflineCopyKind.offlineDownload &&
              copy.intentId == intentId,
        )
        .map((copy) => copy.id)
        .toList();
    final affectedPayloadIds = <String>{};
    for (final copyId in copyIds) {
      final payloadId = _copies[copyId]?.payloadId;
      if (payloadId != null) affectedPayloadIds.add(payloadId);
    }
    var freedBytes = 0;
    for (final copyId in copyIds) {
      freedBytes += _copies.remove(copyId)!.totalBytes;
    }
    for (final payloadId in affectedPayloadIds) {
      _deletePayloadIfUnreferenced(payloadId);
    }

    return OfflineRemovalSummary(
      intentId: intentId,
      removedTaskCount: removedTasks,
      removedCopyCount: copyIds.length,
      freedBytes: freedBytes,
    );
  }

  @override
  DownloadTask? taskById(String id) => _tasks[id];

  @override
  List<DownloadTask> listTasks({String? intentId, String? novelId}) {
    final values = _tasks.values.where((task) {
      return (intentId == null || task.intentId == intentId) &&
          (novelId == null || task.novelId == novelId);
    }).toList()..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(values);
  }

  @override
  void saveTask(DownloadTask task) {
    final intent = _requireIntent(task.intentId);
    if (intent.novelId != task.novelId) {
      throw StateError('Task ${task.id} targets a different novel.');
    }
    final existing = _tasks[task.id];
    if (existing == null) {
      if (task.state != DownloadTaskState.queued || task.revision != 0) {
        throw StateError('A new task must begin at queued revision 0.');
      }
    } else {
      _requireSameTaskIdentity(existing, task);
      if (task.revision != existing.revision + 1) {
        throw StateError(
          'Task ${task.id} has stale revision ${task.revision}; '
          'expected ${existing.revision + 1}.',
        );
      }
    }
    _tasks[task.id] = task;
  }

  @override
  OfflineChapterCopy commitStoredTask({
    required String taskId,
    required OfflineChapterCopy copy,
    required DateTime now,
  }) {
    final task = _tasks[taskId];
    if (task == null) throw StateError('Unknown task $taskId.');
    if (task.state != DownloadTaskState.storing) {
      throw StateError('Task $taskId is not ready to store.');
    }
    if (copy.kind != OfflineCopyKind.offlineDownload ||
        copy.intentId != task.intentId ||
        copy.novelId != task.novelId ||
        copy.chapterId != task.chapterId ||
        copy.translationSource != task.translationSource) {
      throw StateError('Stored copy does not match task $taskId.');
    }
    if (_copies.containsKey(copy.id)) {
      throw StateError('Copy ${copy.id} already exists.');
    }
    _validateCopyPayloadReference(copy);

    // Validate every precondition before applying this in-memory transaction.
    final completed = task.markStored(now, copyId: copy.id);
    _copies[copy.id] = copy;
    _tasks[task.id] = completed;
    return copy;
  }

  @override
  DownloadProgressSummary progressSummary({String? intentId}) {
    return DownloadProgressSummary.fromTasks(listTasks(intentId: intentId));
  }

  @override
  List<NovelDownloadProgressSummary> progressByNovel() {
    final grouped = <String, List<DownloadTask>>{};
    for (final task in _tasks.values) {
      final key = '${task.novelId}\u0000${task.translationSource.name}';
      grouped.putIfAbsent(key, () => []).add(task);
    }
    final keys = grouped.keys.toList()..sort();
    return List.unmodifiable([
      for (final key in keys)
        NovelDownloadProgressSummary(
          novelId: grouped[key]!.first.novelId,
          translationSource: grouped[key]!.first.translationSource,
          progress: DownloadProgressSummary.fromTasks(grouped[key]!),
        ),
    ]);
  }

  @override
  OfflineChapterCopy? copyById(String id) => _copies[id];

  @override
  List<OfflineChapterCopy> listCopies({
    String? novelId,
    OfflineCopyKind? kind,
  }) {
    final values = _copies.values.where((copy) {
      return (novelId == null || copy.novelId == novelId) &&
          (kind == null || copy.kind == kind);
    }).toList()..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(values);
  }

  @override
  void saveCopy(OfflineChapterCopy copy) {
    if (copy.kind == OfflineCopyKind.offlineDownload) {
      final intent = _requireIntent(copy.intentId!);
      if (intent.novelId != copy.novelId) {
        throw StateError('Copy ${copy.id} targets a different novel.');
      }
    }
    _validateCopyPayloadReference(copy);
    final oldPayloadId = _copies[copy.id]?.payloadId;
    _copies[copy.id] = copy;
    if (oldPayloadId != null && oldPayloadId != copy.payloadId) {
      _deletePayloadIfUnreferenced(oldPayloadId);
    }
  }

  @override
  void touchCopy(String id, DateTime readAt) {
    final copy = _copies[id];
    if (copy == null) throw StateError('Unknown copy $id.');
    if (readAt.isBefore(copy.lastReadAt)) {
      throw ArgumentError.value(
        readAt,
        'readAt',
        'Last-read time cannot move backwards.',
      );
    }
    _copies[id] = copy.touch(readAt);
  }

  @override
  List<OfflineChapterCopy> evictCacheTo({
    required int maxBytes,
    Set<ChapterRef> protectedChapters = const {},
  }) {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    var cacheBytes = _copies.values
        .where((copy) => copy.kind == OfflineCopyKind.cacheCopy)
        .fold<int>(0, (sum, copy) => sum + copy.totalBytes);
    if (cacheBytes <= maxBytes) return const [];

    final candidates =
        _copies.values
            .where(
              (copy) =>
                  copy.kind == OfflineCopyKind.cacheCopy &&
                  !protectedChapters.contains(copy.chapter),
            )
            .toList()
          ..sort((a, b) {
            final readOrder = a.lastReadAt.compareTo(b.lastReadAt);
            if (readOrder != 0) return readOrder;
            final storedOrder = a.storedAt.compareTo(b.storedAt);
            if (storedOrder != 0) return storedOrder;
            return a.id.compareTo(b.id);
          });

    final evicted = <OfflineChapterCopy>[];
    for (final copy in candidates) {
      if (cacheBytes <= maxBytes) break;
      _copies.remove(copy.id);
      if (copy.payloadId case final payloadId?) {
        _deletePayloadIfUnreferenced(payloadId);
      }
      cacheBytes -= copy.totalBytes;
      evicted.add(copy);
    }
    return List.unmodifiable(evicted);
  }

  @override
  OfflineStorageSummary storageSummary() {
    return OfflineStorageSummary.fromCopies(_copies.values);
  }

  @override
  List<CachedNovelOutline> listCachedNovels() {
    final values = _outlines.values.toList()
      ..sort((a, b) {
        final fetchedOrder = b.fetchedAt.compareTo(a.fetchedAt);
        return fetchedOrder != 0 ? fetchedOrder : a.id.compareTo(b.id);
      });
    return List.unmodifiable(values);
  }

  @override
  CachedNovelDetail? novelDetail(String novelId) => _details[novelId];

  @override
  CachedChapterPayload? chapterPayload({
    required String novelId,
    required String chapterId,
  }) {
    final values =
        _payloads.values
            .where(
              (payload) =>
                  payload.novelId == novelId && payload.chapterId == chapterId,
            )
            .toList()
          ..sort(_newestPayloadFirst);
    return values.firstOrNull;
  }

  @override
  CachedChapterPayload? chapterPayloadById(String payloadId) {
    return _payloads[payloadId];
  }

  @override
  List<CachedChapterPayload> listChapterPayloads(String novelId) {
    final byChapter = <String, CachedChapterPayload>{};
    for (final payload in _payloads.values.where(
      (payload) => payload.novelId == novelId,
    )) {
      final existing = byChapter[payload.chapterId];
      if (existing == null || _newestPayloadFirst(payload, existing) < 0) {
        byChapter[payload.chapterId] = payload;
      }
    }
    final values = byChapter.values.toList()
      ..sort((a, b) {
        final indexOrder = a.index.compareTo(b.index);
        return indexOrder != 0 ? indexOrder : a.id.compareTo(b.id);
      });
    return List.unmodifiable(values);
  }

  @override
  void upsertNovelOutline(CachedNovelOutline outline) {
    _outlines[outline.id] = outline;
    final detail = _details[outline.id];
    if (detail != null) {
      _details[outline.id] = CachedNovelDetail(
        outline: outline,
        synopsis: detail.synopsis,
        points: detail.points,
        views: detail.views,
        originalUrl: detail.originalUrl,
        sections: detail.sections,
      );
    }
  }

  @override
  void upsertNovelDetail(CachedNovelDetail detail) {
    _outlines[detail.outline.id] = detail.outline;
    _details[detail.outline.id] = detail;
  }

  @override
  void upsertChapterPayload(CachedChapterPayload payload) {
    _validatePayloadIdentity(payload);
    _payloads[payload.id] = payload;
  }

  @override
  void cacheChapterPayload({
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  }) {
    _validatePayloadCopy(
      payload: payload,
      copy: copy,
      expectedKind: OfflineCopyKind.cacheCopy,
    );
    _validatePayloadIdentity(payload);
    if (_protectedCopyReferencesPayload(payload.id)) {
      _payloads[payload.id] = payload;
      final redundantIds = [
        for (final candidate in _copies.values)
          if (candidate.kind == OfflineCopyKind.cacheCopy &&
              candidate.payloadId == payload.id)
            candidate.id,
      ];
      for (final id in redundantIds) {
        _copies.remove(id);
      }
      return;
    }
    final existing = _copies[copy.id];
    if (existing != null && existing.kind != OfflineCopyKind.cacheCopy) {
      throw StateError('A Cache Copy cannot replace a protected copy.');
    }
    if (existing != null &&
        (existing.novelId != copy.novelId ||
            existing.chapterId != copy.chapterId ||
            existing.translationSource != copy.translationSource)) {
      throw StateError('A Cache Copy ID cannot change content identity.');
    }

    final replacedPayloadIds = <String>{?existing?.payloadId};
    final duplicateIds = <String>[
      for (final candidate in _copies.values)
        if (candidate.id != copy.id &&
            candidate.kind == OfflineCopyKind.cacheCopy &&
            candidate.novelId == copy.novelId &&
            candidate.chapterId == copy.chapterId &&
            candidate.translationSource == copy.translationSource)
          candidate.id,
    ];
    for (final duplicateId in duplicateIds) {
      final duplicate = _copies.remove(duplicateId)!;
      if (duplicate.payloadId case final payloadId?) {
        replacedPayloadIds.add(payloadId);
      }
    }
    _payloads[payload.id] = payload;
    _copies[copy.id] = copy;
    for (final oldPayloadId in replacedPayloadIds) {
      if (oldPayloadId != payload.id) {
        _deletePayloadIfUnreferenced(oldPayloadId);
      }
    }
  }

  @override
  OfflineChapterCopy commitDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
    required DateTime now,
  }) {
    final task = _tasks[taskId];
    if (task == null) throw StateError('Unknown task $taskId.');
    if (task.state != DownloadTaskState.storing) {
      throw StateError('Task $taskId is not ready to store.');
    }
    if (copy.intentId != task.intentId ||
        copy.novelId != task.novelId ||
        copy.chapterId != task.chapterId ||
        copy.translationSource != task.translationSource) {
      throw StateError('Stored copy does not match task $taskId.');
    }
    _validatePayloadCopy(
      payload: payload,
      copy: copy,
      expectedKind: OfflineCopyKind.offlineDownload,
    );
    if (_copies.containsKey(copy.id)) {
      throw StateError('Copy ${copy.id} already exists.');
    }
    _validatePayloadIdentity(payload);
    final completed = task.markStored(now, copyId: copy.id);

    _payloads[payload.id] = payload;
    _copies[copy.id] = copy;
    _tasks[task.id] = completed;
    return copy;
  }

  @override
  OfflineChapterCopy refreshDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  }) {
    final task = _tasks[taskId];
    if (task == null) throw StateError('Unknown task $taskId.');
    if (task.state != DownloadTaskState.stored || task.storedCopyId == null) {
      throw StateError('Task $taskId has not stored a chapter download.');
    }
    final existing = _copies[task.storedCopyId!];
    if (existing == null || existing.kind != OfflineCopyKind.offlineDownload) {
      throw StateError('Task $taskId has no protected stored copy.');
    }
    if (copy.id != existing.id ||
        copy.kind != OfflineCopyKind.offlineDownload ||
        copy.intentId != existing.intentId ||
        copy.novelId != existing.novelId ||
        copy.chapterId != existing.chapterId ||
        copy.translationSource != existing.translationSource ||
        copy.intentId != task.intentId ||
        copy.novelId != task.novelId ||
        copy.chapterId != task.chapterId ||
        copy.translationSource != task.translationSource ||
        copy.storedAt.isBefore(existing.storedAt) ||
        copy.lastReadAt.isBefore(existing.lastReadAt)) {
      throw StateError('Refreshed copy does not match stored task $taskId.');
    }
    _validatePayloadCopy(
      payload: payload,
      copy: copy,
      expectedKind: OfflineCopyKind.offlineDownload,
    );
    _validatePayloadIdentity(payload);

    final oldPayloadId = existing.payloadId;
    final oldPayload = oldPayloadId == null ? null : _payloads[oldPayloadId];
    if (oldPayload != null &&
        payload.fetchedAt.isBefore(oldPayload.fetchedAt)) {
      throw StateError('A protected download cannot refresh to older data.');
    }
    _payloads[payload.id] = payload;
    _copies[copy.id] = copy;
    if (oldPayloadId != null && oldPayloadId != payload.id) {
      _deletePayloadIfUnreferenced(oldPayloadId);
    }
    return copy;
  }

  @override
  ContentCacheRemovalSummary removeCachedNovel(String novelId) {
    final cacheCopyIds = _copies.values
        .where(
          (copy) =>
              copy.novelId == novelId && copy.kind == OfflineCopyKind.cacheCopy,
        )
        .map((copy) => copy.id)
        .toList();
    final protectedPayloadIds = <String>{
      for (final copy in _copies.values)
        if (copy.novelId == novelId &&
            copy.kind == OfflineCopyKind.offlineDownload &&
            copy.payloadId != null)
          copy.payloadId!,
    };
    for (final copyId in cacheCopyIds) {
      _copies.remove(copyId);
    }
    final preserveManifest =
        _copies.values.any(
          (copy) =>
              copy.novelId == novelId &&
              copy.kind == OfflineCopyKind.offlineDownload,
        ) ||
        _intents.values.any((intent) => intent.novelId == novelId);
    final retainedDownloadManifest =
        preserveManifest &&
        (_outlines.containsKey(novelId) || _details.containsKey(novelId));
    if (!preserveManifest) {
      _outlines.remove(novelId);
      _details.remove(novelId);
    }
    final payloadIds = _payloads.values
        .where(
          (payload) =>
              payload.novelId == novelId &&
              !protectedPayloadIds.contains(payload.id),
        )
        .map((payload) => payload.id)
        .toList();
    for (final payloadId in payloadIds) {
      _payloads.remove(payloadId);
    }
    return ContentCacheRemovalSummary(
      novelId: novelId,
      removedCacheCopyCount: cacheCopyIds.length,
      removedPayloadCount: payloadIds.length,
      retainedProtectedPayloadCount: protectedPayloadIds.length,
      retainedDownloadManifest: retainedDownloadManifest,
    );
  }

  void _validateCopyPayloadReference(OfflineChapterCopy copy) {
    final payloadId = copy.payloadId;
    if (payloadId == null) return;
    final payload = _payloads[payloadId];
    if (payload == null) {
      throw StateError('Copy ${copy.id} references a missing chapter payload.');
    }
    _validatePayloadCopy(payload: payload, copy: copy, expectedKind: copy.kind);
  }

  void _validatePayloadIdentity(CachedChapterPayload payload) {
    final existing = _payloads[payload.id];
    if (existing != null &&
        (existing.novelId != payload.novelId ||
            existing.chapterId != payload.chapterId ||
            existing.revision != payload.revision ||
            existing.etag != payload.etag)) {
      throw StateError('Chapter payload ${payload.id} identity cannot change.');
    }
  }

  static void _validatePayloadCopy({
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
    required OfflineCopyKind expectedKind,
  }) {
    if (copy.kind != expectedKind ||
        copy.payloadId != payload.id ||
        copy.novelId != payload.novelId ||
        copy.chapterId != payload.chapterId ||
        copy.revision != payload.revision ||
        copy.etag != payload.etag) {
      throw StateError('Offline copy does not identify the supplied payload.');
    }
    final translation = payload.translationFor(copy.translationSource);
    final hasCompleteTranslation =
        translation?.availability == TranslationAvailability.complete;
    if (copy.hasTranslation != hasCompleteTranslation) {
      throw StateError(
        'Offline copy translation availability disagrees with its payload.',
      );
    }
  }

  bool _protectedCopyReferencesPayload(String payloadId) {
    return _copies.values.any(
      (copy) =>
          copy.kind == OfflineCopyKind.offlineDownload &&
          copy.payloadId == payloadId,
    );
  }

  void _deletePayloadIfUnreferenced(String payloadId) {
    final isReferenced = _copies.values.any(
      (copy) => copy.payloadId == payloadId,
    );
    if (!isReferenced) _payloads.remove(payloadId);
  }

  static int _newestPayloadFirst(
    CachedChapterPayload a,
    CachedChapterPayload b,
  ) {
    final fetchedOrder = b.fetchedAt.compareTo(a.fetchedAt);
    return fetchedOrder != 0 ? fetchedOrder : b.id.compareTo(a.id);
  }

  DownloadIntent _requireIntent(String id) {
    final intent = _intents[id];
    if (intent == null) throw StateError('Unknown download intent $id.');
    return intent;
  }

  static String _taskId({
    required String intentId,
    required String chapterId,
    required String sourceName,
  }) {
    return [
      intentId,
      sourceName,
      chapterId,
    ].map(Uri.encodeComponent).join('::');
  }

  static void _requireSameTaskIdentity(
    DownloadTask existing,
    DownloadTask replacement,
  ) {
    if (existing.intentId != replacement.intentId ||
        existing.novelId != replacement.novelId ||
        existing.chapterId != replacement.chapterId ||
        existing.translationSource != replacement.translationSource ||
        existing.createdAt != replacement.createdAt) {
      throw StateError('Task ${existing.id} identity cannot change.');
    }
  }
}
