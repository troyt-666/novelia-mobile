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

  void removeIntent(String intentId, DateTime now);
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
}

abstract interface class OfflineContentRepository {
  OfflineChapterCopy? copyById(String id);

  List<OfflineChapterCopy> listCopies({String? novelId, OfflineCopyKind? kind});

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
