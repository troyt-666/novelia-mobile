import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../account/account_sync_models.dart';
import '../account/remote_history_outbox_repository.dart';
import '../model/reader_models.dart';
import '../offline/content_models.dart';
import '../offline/content_repository.dart';
import '../offline/offline_models.dart';
import '../offline/offline_repository.dart';
import 'app_database.dart';
import 'local_state_repository.dart';

/// Durable SQLite implementation of the offline and local-state contracts.
final class SqliteOfflineRepository
    implements
        OfflineRepository,
        LocalStateRepository,
        ContentRepository,
        RemoteHistoryOutboxRepository {
  SqliteOfflineRepository._(this._database, this._closeDatabase);

  static Future<SqliteOfflineRepository> openApplicationSupport({
    String fileName = NoveliaDatabase.defaultFileName,
  }) async {
    final database = await NoveliaDatabase.openApplicationSupport(
      fileName: fileName,
    );
    return SqliteOfflineRepository._(database, true);
  }

  static SqliteOfflineRepository openFile(String filePath) {
    return SqliteOfflineRepository._(NoveliaDatabase.openFile(filePath), true);
  }

  static SqliteOfflineRepository openInMemory() {
    return SqliteOfflineRepository._(NoveliaDatabase.openInMemory(), true);
  }

  /// Adopts or borrows an existing connection and migrates it to the current
  /// schema. This is primarily useful for migration and integration tests.
  static SqliteOfflineRepository fromDatabase(
    Database database, {
    bool closeOnDispose = false,
  }) {
    NoveliaDatabase.initialize(database);
    return SqliteOfflineRepository._(database, closeOnDispose);
  }

  final Database _database;
  final bool _closeDatabase;
  bool _closed = false;

  int get schemaVersion => _database.userVersion;

  bool get passesIntegrityCheck {
    _checkOpen();
    final row = _database.select('PRAGMA integrity_check;').single;
    return row.values.single == 'ok';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_closeDatabase) _database.close();
  }

  @override
  void saveIntent(DownloadIntent intent) {
    _checkOpen();
    if (intent.id.isEmpty || intent.novelId.isEmpty) {
      throw ArgumentError('Intent and novel IDs must be non-empty.');
    }
    final kind = intent is ChapterDownloadIntent ? 'chapter' : 'novel';
    final chapterId = switch (intent) {
      ChapterDownloadIntent(:final chapterId) => chapterId,
      NovelDownloadIntent() => null,
    };
    _database.execute(
      '''
      INSERT INTO download_intents (
        id, novel_id, intent_kind, chapter_id, translation_source,
        created_at_us, enabled
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        novel_id = excluded.novel_id,
        intent_kind = excluded.intent_kind,
        chapter_id = excluded.chapter_id,
        translation_source = excluded.translation_source,
        created_at_us = excluded.created_at_us,
        enabled = excluded.enabled;
    ''',
      [
        intent.id,
        intent.novelId,
        kind,
        chapterId,
        intent.translationSource.name,
        _timestamp(intent.createdAt),
        _boolean(intent.enabled),
      ],
    );
  }

  @override
  DownloadIntent? intentById(String id) {
    _checkOpen();
    final rows = _database.select(
      'SELECT * FROM download_intents WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _intentFromRow(rows.single);
  }

  @override
  List<DownloadIntent> listIntents() {
    _checkOpen();
    return List.unmodifiable(
      _database
          .select('SELECT * FROM download_intents ORDER BY id;')
          .map(_intentFromRow),
    );
  }

  @override
  List<DownloadTask> reconcileIntent({
    required String intentId,
    required Iterable<String> knownChapterIds,
    required DateTime now,
  }) {
    _checkOpen();
    return _transaction(() {
      final intent = _requireIntent(intentId);
      final created = <DownloadTask>[];
      for (final chapterId in intent.targetChapterIds(knownChapterIds)) {
        final taskId = _taskId(
          intentId: intent.id,
          chapterId: chapterId,
          sourceName: intent.translationSource.name,
        );
        if (_taskById(taskId) != null) continue;
        final task = DownloadTask.queued(
          id: taskId,
          intentId: intent.id,
          novelId: intent.novelId,
          chapterId: chapterId,
          translationSource: intent.translationSource,
          now: now,
        );
        _insertTask(task);
        created.add(task);
      }
      return List.unmodifiable(created);
    });
  }

  @override
  List<DownloadTask> requeueInterruptedTasks({
    required String intentId,
    required DateTime now,
  }) {
    _checkOpen();
    return _transaction(() {
      final intent = _requireIntent(intentId);
      if (!intent.enabled) return const <DownloadTask>[];
      final replacements = <DownloadTask>[
        for (final task in _listTasks(intentId: intentId))
          if (task.isActive ||
              task.state == DownloadTaskState.paused ||
              (task.state == DownloadTaskState.failed &&
                  task.failure?.retryable == true))
            task.requeueForRestart(now),
      ];
      for (final task in replacements) {
        _updateTask(task);
      }
      return List.unmodifiable(replacements);
    });
  }

  @override
  void pauseIntent(String intentId, DateTime now) {
    _checkOpen();
    _transaction(() {
      final intent = _requireIntent(intentId);
      _writeIntentEnabled(intent.withEnabled(false));
      for (final task in _listTasks(intentId: intentId)) {
        if (task.state == DownloadTaskState.queued || task.isActive) {
          _updateTask(task.pause(now));
        }
      }
    });
  }

  @override
  void resumeIntent(String intentId, DateTime now) {
    _checkOpen();
    _transaction(() {
      final intent = _requireIntent(intentId);
      _writeIntentEnabled(intent.withEnabled(true));
      for (final task in _listTasks(intentId: intentId)) {
        if (task.state == DownloadTaskState.paused) {
          _updateTask(task.resume(now));
        }
      }
    });
  }

  @override
  void removeIntent(String intentId, DateTime now) {
    _checkOpen();
    _transaction(() {
      _requireIntent(intentId);
      for (final task in _listTasks(intentId: intentId)) {
        if (task.state != DownloadTaskState.removed) {
          _updateTask(task.remove(now));
        }
      }

      final affectedPayloadIds = _database
          .select(
            'SELECT payload_id FROM offline_chapter_copies '
            'WHERE copy_kind = ? AND intent_id = ? AND payload_id IS NOT NULL;',
            [OfflineCopyKind.offlineDownload.name, intentId],
          )
          .map((row) => _string(row['payload_id']))
          .toList();
      _database.execute(
        'DELETE FROM offline_chapter_copies WHERE copy_kind = ? AND intent_id = ?;',
        [OfflineCopyKind.offlineDownload.name, intentId],
      );
      for (final payloadId in affectedPayloadIds) {
        _deletePayloadIfUnreferenced(payloadId);
      }
      _database.execute('DELETE FROM download_intents WHERE id = ?;', [
        intentId,
      ]);
    });
  }

  @override
  DownloadTask? taskById(String id) {
    _checkOpen();
    return _taskById(id);
  }

  DownloadTask? _taskById(String id) {
    final rows = _database.select(
      'SELECT * FROM download_tasks WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _taskFromRow(rows.single);
  }

  @override
  List<DownloadTask> listTasks({String? intentId, String? novelId}) {
    _checkOpen();
    return _listTasks(intentId: intentId, novelId: novelId);
  }

  List<DownloadTask> _listTasks({String? intentId, String? novelId}) {
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (intentId != null) {
      clauses.add('intent_id = ?');
      arguments.add(intentId);
    }
    if (novelId != null) {
      clauses.add('novel_id = ?');
      arguments.add(novelId);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    return List.unmodifiable(
      _database
          .select('SELECT * FROM download_tasks$where ORDER BY id;', arguments)
          .map(_taskFromRow),
    );
  }

  @override
  void saveTask(DownloadTask task) {
    _checkOpen();
    _transaction(() {
      final intent = _requireIntent(task.intentId);
      if (intent.novelId != task.novelId) {
        throw StateError('Task ${task.id} targets a different novel.');
      }
      final existing = _taskById(task.id);
      if (existing == null) {
        if (task.state != DownloadTaskState.queued || task.revision != 0) {
          throw StateError('A new task must begin at queued revision 0.');
        }
        _insertTask(task);
      } else {
        _requireSameTaskIdentity(existing, task);
        if (task.revision != existing.revision + 1) {
          throw StateError(
            'Task ${task.id} has stale revision ${task.revision}; '
            'expected ${existing.revision + 1}.',
          );
        }
        _updateTask(task);
      }
    });
  }

  @override
  OfflineChapterCopy commitStoredTask({
    required String taskId,
    required OfflineChapterCopy copy,
    required DateTime now,
  }) {
    _checkOpen();
    return _transaction(() {
      final task = _taskById(taskId);
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
      if (_copyById(copy.id) != null) {
        throw StateError('Copy ${copy.id} already exists.');
      }
      _validateCopyPayloadReference(copy);

      final completed = task.markStored(now, copyId: copy.id);
      _insertCopy(copy);
      _updateTask(completed);
      return copy;
    });
  }

  @override
  OfflineChapterCopy? copyById(String id) {
    _checkOpen();
    return _copyById(id);
  }

  OfflineChapterCopy? _copyById(String id) {
    final rows = _database.select(
      'SELECT * FROM offline_chapter_copies WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _copyFromRow(rows.single);
  }

  bool _protectedCopyReferencesPayload(String payloadId) {
    final rows = _database.select(
      'SELECT 1 FROM offline_chapter_copies '
      'WHERE copy_kind = ? AND payload_id = ? LIMIT 1;',
      [OfflineCopyKind.offlineDownload.name, payloadId],
    );
    return rows.isNotEmpty;
  }

  void _deleteCacheCopiesForPayload(String payloadId) {
    _database.execute(
      'DELETE FROM offline_chapter_copies '
      'WHERE copy_kind = ? AND payload_id = ?;',
      [OfflineCopyKind.cacheCopy.name, payloadId],
    );
  }

  @override
  List<OfflineChapterCopy> listCopies({
    String? novelId,
    OfflineCopyKind? kind,
  }) {
    _checkOpen();
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (novelId != null) {
      clauses.add('novel_id = ?');
      arguments.add(novelId);
    }
    if (kind != null) {
      clauses.add('copy_kind = ?');
      arguments.add(kind.name);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM offline_chapter_copies$where ORDER BY id;',
            arguments,
          )
          .map(_copyFromRow),
    );
  }

  @override
  void touchCopy(String id, DateTime readAt) {
    _checkOpen();
    final copy = _copyById(id);
    if (copy == null) throw StateError('Unknown copy $id.');
    if (readAt.isBefore(copy.lastReadAt)) {
      throw ArgumentError.value(
        readAt,
        'readAt',
        'Last-read time cannot move backwards.',
      );
    }
    _database.execute(
      'UPDATE offline_chapter_copies SET last_read_at_us = ? WHERE id = ?;',
      [_timestamp(readAt), id],
    );
  }

  void touchChapterCopies(String novelId, String chapterId, DateTime readAt) {
    _checkOpen();
    final timestamp = _timestamp(readAt);
    _database.execute(
      'UPDATE offline_chapter_copies SET last_read_at_us = ? '
      'WHERE novel_id = ? AND chapter_id = ? AND last_read_at_us < ?;',
      [timestamp, novelId, chapterId, timestamp],
    );
  }

  @override
  List<OfflineChapterCopy> evictCacheTo({
    required int maxBytes,
    Set<ChapterRef> protectedChapters = const {},
  }) {
    _checkOpen();
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    return _transaction(() {
      var cacheBytes = _int(
        _database.select(
          'SELECT COALESCE(SUM(original_bytes + COALESCE(translation_bytes, 0)), 0) '
          'AS bytes FROM offline_chapter_copies WHERE copy_kind = ?;',
          [OfflineCopyKind.cacheCopy.name],
        ).single['bytes'],
      );
      if (cacheBytes <= maxBytes) return const <OfflineChapterCopy>[];
      final candidates =
          listCopies(kind: OfflineCopyKind.cacheCopy)
              .where((copy) => !protectedChapters.contains(copy.chapter))
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
        _database.execute('DELETE FROM offline_chapter_copies WHERE id = ?;', [
          copy.id,
        ]);
        if (copy.payloadId case final payloadId?) {
          _deletePayloadIfUnreferenced(payloadId);
        }
        cacheBytes -= copy.totalBytes;
        evicted.add(copy);
      }
      return List.unmodifiable(evicted);
    });
  }

  @override
  OfflineStorageSummary storageSummary() {
    _checkOpen();
    return OfflineStorageSummary.fromCopies(listCopies());
  }

  @override
  List<CachedNovelOutline> listCachedNovels({Iterable<String>? novelIds}) {
    _checkOpen();
    final ids = novelIds?.toSet().toList();
    if (ids != null && ids.isEmpty) return const [];
    final where = ids == null
        ? ''
        : 'WHERE id IN (${List.filled(ids.length, '?').join(',')}) ';
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM cached_novels $where'
            'ORDER BY fetched_at_us DESC, id;',
            ids ?? const [],
          )
          .map(_outlineFromRow),
    );
  }

  CachedNovelOutline? cachedNovelOutline(String novelId) {
    _checkOpen();
    final rows = _database.select('SELECT * FROM cached_novels WHERE id = ?;', [
      novelId,
    ]);
    return rows.isEmpty ? null : _outlineFromRow(rows.single);
  }

  @override
  CachedNovelDetail? novelDetail(String novelId) {
    _checkOpen();
    final rows = _database.select('SELECT * FROM cached_novels WHERE id = ?;', [
      novelId,
    ]);
    if (rows.isEmpty || rows.single['synopsis'] == null) return null;
    final row = rows.single;
    final sectionRows = _database.select(
      'SELECT * FROM cached_toc_sections WHERE novel_id = ? '
      'ORDER BY section_order;',
      [novelId],
    );
    final sections = <CachedTocSection>[];
    for (final sectionRow in sectionRows) {
      final sectionId = _string(sectionRow['section_id']);
      final chapters = _database
          .select(
            'SELECT * FROM cached_toc_chapters '
            'WHERE novel_id = ? AND section_id = ? ORDER BY chapter_order;',
            [novelId, sectionId],
          )
          .map(
            (chapterRow) => CachedTocChapter(
              id: _string(chapterRow['chapter_id']),
              index: _int(chapterRow['chapter_index']),
              chineseTitle: _string(chapterRow['chinese_title']),
              japaneseTitle: _string(chapterRow['japanese_title']),
              publishedAt: _nullableDateTime(chapterRow['published_at_us']),
            ),
          )
          .toList();
      sections.add(
        CachedTocSection(
          id: sectionId,
          title: _string(sectionRow['title']),
          chapters: chapters,
        ),
      );
    }
    return CachedNovelDetail(
      outline: _outlineFromRow(row),
      synopsis: _string(row['synopsis']),
      points: _nullableInt(row['points']),
      views: _nullableInt(row['views']),
      originalUrl: row['original_url'] as String?,
      sections: sections,
    );
  }

  @override
  CachedChapterPayload? chapterPayload({
    required String novelId,
    required String chapterId,
  }) {
    _checkOpen();
    final rows = _database.select(
      'SELECT * FROM cached_chapter_payloads '
      'WHERE novel_id = ? AND chapter_id = ? '
      'ORDER BY fetched_at_us DESC, payload_id DESC LIMIT 1;',
      [novelId, chapterId],
    );
    return rows.isEmpty ? null : _payloadFromRow(rows.single);
  }

  @override
  CachedChapterPayload? chapterPayloadById(String payloadId) {
    _checkOpen();
    return _payloadById(payloadId);
  }

  @override
  void upsertNovelOutline(CachedNovelOutline outline) {
    _checkOpen();
    _upsertNovelOutline(outline);
  }

  @override
  void upsertNovelOutlines(Iterable<CachedNovelOutline> outlines) {
    _checkOpen();
    _transaction(() {
      for (final outline in outlines) {
        _upsertNovelOutline(outline);
      }
    });
  }

  @override
  void upsertNovelDetail(CachedNovelDetail detail) {
    _checkOpen();
    _transaction(() {
      _upsertNovelOutline(detail.outline);
      _database.execute(
        'UPDATE cached_novels SET synopsis = ?, points = ?, views = ?, '
        'original_url = ? WHERE id = ?;',
        [
          detail.synopsis,
          detail.points,
          detail.views,
          detail.originalUrl,
          detail.outline.id,
        ],
      );
      _database.execute('DELETE FROM cached_toc_sections WHERE novel_id = ?;', [
        detail.outline.id,
      ]);
      for (
        var sectionOrder = 0;
        sectionOrder < detail.sections.length;
        sectionOrder++
      ) {
        final section = detail.sections[sectionOrder];
        _database.execute(
          'INSERT INTO cached_toc_sections '
          '(novel_id, section_id, section_order, title) VALUES (?, ?, ?, ?);',
          [detail.outline.id, section.id, sectionOrder, section.title],
        );
        for (
          var chapterOrder = 0;
          chapterOrder < section.chapters.length;
          chapterOrder++
        ) {
          final chapter = section.chapters[chapterOrder];
          _database.execute(
            'INSERT INTO cached_toc_chapters '
            '(novel_id, chapter_id, section_id, chapter_order, chapter_index, '
            'chinese_title, japanese_title, published_at_us) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
            [
              detail.outline.id,
              chapter.id,
              section.id,
              chapterOrder,
              chapter.index,
              chapter.chineseTitle,
              chapter.japaneseTitle,
              chapter.publishedAt == null
                  ? null
                  : _timestamp(chapter.publishedAt!),
            ],
          );
        }
      }
    });
  }

  @override
  void cacheChapterPayload({
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  }) {
    _checkOpen();
    _transaction(() {
      _validatePayloadCopy(
        payload: payload,
        copy: copy,
        expectedKind: OfflineCopyKind.cacheCopy,
      );
      final existing = _copyById(copy.id);
      if (existing != null && existing.kind != OfflineCopyKind.cacheCopy) {
        throw StateError('A Cache Copy cannot replace a protected copy.');
      }
      if (existing != null &&
          (existing.novelId != copy.novelId ||
              existing.chapterId != copy.chapterId ||
              existing.translationSource != copy.translationSource)) {
        throw StateError('A Cache Copy ID cannot change content identity.');
      }
      if (_protectedCopyReferencesPayload(payload.id)) {
        _upsertChapterPayload(payload);
        _deleteCacheCopiesForPayload(payload.id);
        return;
      }
      final replacedPayloadIds = <String>{?existing?.payloadId};
      final duplicates = _database.select(
        'SELECT id, payload_id FROM offline_chapter_copies '
        'WHERE copy_kind = ? AND novel_id = ? AND chapter_id = ? '
        'AND translation_source = ? AND id <> ?;',
        [
          OfflineCopyKind.cacheCopy.name,
          copy.novelId,
          copy.chapterId,
          copy.translationSource.name,
          copy.id,
        ],
      );
      for (final duplicate in duplicates) {
        final payloadId = duplicate['payload_id'] as String?;
        if (payloadId != null) replacedPayloadIds.add(payloadId);
        _database.execute('DELETE FROM offline_chapter_copies WHERE id = ?;', [
          _string(duplicate['id']),
        ]);
      }
      _upsertChapterPayload(payload);
      _upsertCopy(copy);
      for (final oldPayloadId in replacedPayloadIds) {
        if (oldPayloadId != payload.id) {
          _deletePayloadIfUnreferenced(oldPayloadId);
        }
      }
    });
  }

  @override
  OfflineChapterCopy commitDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
    required DateTime now,
  }) {
    _checkOpen();
    return _transaction(() {
      final task = _taskById(taskId);
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
      if (_copyById(copy.id) != null) {
        throw StateError('Copy ${copy.id} already exists.');
      }

      final completed = task.markStored(now, copyId: copy.id);
      _upsertChapterPayload(payload);
      _insertCopy(copy);
      _updateTask(completed);
      return copy;
    });
  }

  @override
  OfflineChapterCopy refreshDownloadedChapter({
    required String taskId,
    required CachedChapterPayload payload,
    required OfflineChapterCopy copy,
  }) {
    _checkOpen();
    return _transaction(() {
      final task = _taskById(taskId);
      if (task == null) throw StateError('Unknown task $taskId.');
      if (task.state != DownloadTaskState.stored || task.storedCopyId == null) {
        throw StateError('Task $taskId has not stored a chapter download.');
      }
      final existing = _copyById(task.storedCopyId!);
      if (existing == null ||
          existing.kind != OfflineCopyKind.offlineDownload) {
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

      final oldPayloadId = existing.payloadId;
      final oldPayload = oldPayloadId == null
          ? null
          : _payloadById(oldPayloadId);
      if (oldPayload != null &&
          payload.fetchedAt.isBefore(oldPayload.fetchedAt)) {
        throw StateError('A protected download cannot refresh to older data.');
      }
      _upsertChapterPayload(payload);
      _upsertCopy(copy);
      if (oldPayloadId != null && oldPayloadId != payload.id) {
        _deletePayloadIfUnreferenced(oldPayloadId);
      }
      return copy;
    });
  }

  @override
  void removeCachedNovel(String novelId) {
    _checkOpen();
    _transaction(() {
      final preserveManifest =
          _database.select(
            'SELECT EXISTS('
            'SELECT 1 FROM offline_chapter_copies '
            'WHERE novel_id = ? AND copy_kind = ?'
            ') OR EXISTS('
            'SELECT 1 FROM download_intents WHERE novel_id = ?'
            ') AS preserve_manifest;',
            [novelId, OfflineCopyKind.offlineDownload.name, novelId],
          ).single['preserve_manifest'] ==
          1;
      _database.execute(
        'DELETE FROM offline_chapter_copies '
        'WHERE novel_id = ? AND copy_kind = ?;',
        [novelId, OfflineCopyKind.cacheCopy.name],
      );
      if (!preserveManifest) {
        _database.execute('DELETE FROM cached_novels WHERE id = ?;', [novelId]);
      }
      _database.execute(
        'DELETE FROM cached_chapter_payloads AS payload '
        'WHERE payload.novel_id = ? AND NOT EXISTS ('
        'SELECT 1 FROM offline_chapter_copies AS copy '
        'WHERE copy.payload_id = payload.payload_id '
        'AND copy.copy_kind = ?);',
        [novelId, OfflineCopyKind.offlineDownload.name],
      );
    });
  }

  @override
  void saveReadingProgress(LocalReadingProgress progress) {
    _checkOpen();
    _validatePosition(progress.novelId, progress.position);
    _database.execute(
      '''
      INSERT INTO reading_progress (
        novel_id, chapter_id, block_id, intra_block_offset, updated_at_us
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(novel_id) DO UPDATE SET
        chapter_id = excluded.chapter_id,
        block_id = excluded.block_id,
        intra_block_offset = excluded.intra_block_offset,
        updated_at_us = excluded.updated_at_us;
    ''',
      [
        progress.novelId,
        progress.position.chapterId,
        progress.position.blockId,
        progress.position.intraBlockOffset,
        _timestamp(progress.updatedAt),
      ],
    );
  }

  @override
  void queueRemoteHistory(RemoteHistoryOutboxEntry entry) {
    _checkOpen();
    _database.execute(
      '''
      INSERT INTO remote_history_outbox (
        novel_id, provider_id, service_novel_id, chapter_id, occurred_at_us
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(novel_id) DO UPDATE SET
        provider_id = excluded.provider_id,
        service_novel_id = excluded.service_novel_id,
        chapter_id = excluded.chapter_id,
        occurred_at_us = excluded.occurred_at_us
      WHERE excluded.occurred_at_us >= remote_history_outbox.occurred_at_us;
      ''',
      [
        entry.novelId,
        entry.providerId,
        entry.serviceNovelId,
        entry.chapterId,
        _timestamp(entry.occurredAt),
      ],
    );
  }

  @override
  List<RemoteHistoryOutboxEntry> listRemoteHistoryOutbox() {
    _checkOpen();
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM remote_history_outbox '
            'ORDER BY occurred_at_us, novel_id;',
          )
          .map(
            (row) => RemoteHistoryOutboxEntry(
              novelId: _string(row['novel_id']),
              providerId: _string(row['provider_id']),
              serviceNovelId: _string(row['service_novel_id']),
              chapterId: _string(row['chapter_id']),
              occurredAt: _dateTime(row['occurred_at_us']),
            ),
          ),
    );
  }

  @override
  bool removeRemoteHistoryIfUnchanged(RemoteHistoryOutboxEntry entry) {
    _checkOpen();
    _database.execute(
      'DELETE FROM remote_history_outbox '
      'WHERE novel_id = ? AND provider_id = ? AND service_novel_id = ? '
      'AND chapter_id = ? AND occurred_at_us = ?;',
      [
        entry.novelId,
        entry.providerId,
        entry.serviceNovelId,
        entry.chapterId,
        _timestamp(entry.occurredAt),
      ],
    );
    return _database.updatedRows == 1;
  }

  @override
  void clearRemoteHistoryOutbox() {
    _checkOpen();
    _database.execute('DELETE FROM remote_history_outbox;');
  }

  @override
  LocalReadingProgress? readingProgressFor(String novelId) {
    _checkOpen();
    final rows = _database.select(
      'SELECT * FROM reading_progress WHERE novel_id = ?;',
      [novelId],
    );
    return rows.isEmpty ? null : _progressFromRow(rows.single);
  }

  @override
  List<LocalReadingProgress> listReadingProgress() {
    _checkOpen();
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM reading_progress '
            'ORDER BY updated_at_us DESC, novel_id;',
          )
          .map(_progressFromRow),
    );
  }

  @override
  void saveBookmark(LocalBookmark bookmark) {
    _checkOpen();
    if (bookmark.id.isEmpty) throw ArgumentError.value(bookmark.id, 'id');
    _validatePosition(bookmark.novelId, bookmark.position);
    _database.execute(
      '''
      INSERT INTO bookmarks (
        id, novel_id, chapter_id, block_id, intra_block_offset, created_at_us
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        novel_id = excluded.novel_id,
        chapter_id = excluded.chapter_id,
        block_id = excluded.block_id,
        intra_block_offset = excluded.intra_block_offset,
        created_at_us = excluded.created_at_us;
    ''',
      [
        bookmark.id,
        bookmark.novelId,
        bookmark.position.chapterId,
        bookmark.position.blockId,
        bookmark.position.intraBlockOffset,
        _timestamp(bookmark.createdAt),
      ],
    );
  }

  @override
  List<LocalBookmark> listBookmarks({String? novelId}) {
    _checkOpen();
    final where = novelId == null ? '' : ' WHERE novel_id = ?';
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM bookmarks$where '
            'ORDER BY created_at_us DESC, id;',
            novelId == null ? const [] : [novelId],
          )
          .map(_bookmarkFromRow),
    );
  }

  @override
  void removeBookmark(String id) {
    _checkOpen();
    _database.execute('DELETE FROM bookmarks WHERE id = ?;', [id]);
  }

  @override
  void saveLastRoute(LastRouteState state) {
    _checkOpen();
    _database.execute(
      '''
      INSERT INTO last_route_state (
        singleton_id, route_name, novel_id, chapter_id, block_id,
        intra_block_offset, updated_at_us
      ) VALUES (1, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(singleton_id) DO UPDATE SET
        route_name = excluded.route_name,
        novel_id = excluded.novel_id,
        chapter_id = excluded.chapter_id,
        block_id = excluded.block_id,
        intra_block_offset = excluded.intra_block_offset,
        updated_at_us = excluded.updated_at_us;
    ''',
      [
        state.routeName,
        state.novelId,
        state.position?.chapterId,
        state.position?.blockId,
        state.position?.intraBlockOffset,
        _timestamp(state.updatedAt),
      ],
    );
  }

  @override
  LastRouteState? lastRoute() {
    _checkOpen();
    final rows = _database.select(
      'SELECT * FROM last_route_state WHERE singleton_id = 1;',
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final novelId = row['novel_id'] as String?;
    return LastRouteState(
      routeName: _string(row['route_name']),
      novelId: novelId,
      position: novelId == null
          ? null
          : ReadingPosition(
              chapterId: _string(row['chapter_id']),
              blockId: _string(row['block_id']),
              intraBlockOffset: _int(row['intra_block_offset']),
            ),
      updatedAt: _dateTime(row['updated_at_us']),
    );
  }

  @override
  void saveRecentSearches(List<String> queries) {
    _checkOpen();
    final normalized = <String>[];
    for (final query in queries) {
      final trimmed = query.trim();
      if (trimmed.isEmpty || normalized.contains(trimmed)) continue;
      normalized.add(trimmed);
      if (normalized.length == 8) break;
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    _transaction(() {
      _database.execute('DELETE FROM recent_searches;');
      for (var index = 0; index < normalized.length; index++) {
        _database.execute(
          'INSERT INTO recent_searches '
          '(query, display_order, updated_at_us) VALUES (?, ?, ?);',
          [normalized[index], index, now],
        );
      }
    });
  }

  @override
  List<String> recentSearches() {
    _checkOpen();
    return List.unmodifiable(
      _database
          .select(
            'SELECT query FROM recent_searches '
            'ORDER BY display_order ASC LIMIT 8;',
          )
          .map((row) => _string(row['query'])),
    );
  }

  @override
  void saveAppSettings(LocalAppSettings settings) {
    _checkOpen();
    final reader = settings.readerSettings;
    _database.execute(
      '''
      INSERT INTO app_settings (
        singleton_id, reading_mode, translation_source, layout_mode,
        reader_palette, font_family, body_bold, chinese_font_size,
        japanese_font_size, line_height, paragraph_spacing, japanese_opacity,
        page_margin, reading_width, column_layout, orientation_preference,
        text_selection_enabled, tap_page_turn_enabled,
        theme_preference, notify_new_chapters, cache_limit_bytes, updated_at_us
      ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(singleton_id) DO UPDATE SET
        reading_mode = excluded.reading_mode,
        translation_source = excluded.translation_source,
        layout_mode = excluded.layout_mode,
        reader_palette = excluded.reader_palette,
        font_family = excluded.font_family,
        body_bold = excluded.body_bold,
        chinese_font_size = excluded.chinese_font_size,
        japanese_font_size = excluded.japanese_font_size,
        line_height = excluded.line_height,
        paragraph_spacing = excluded.paragraph_spacing,
        japanese_opacity = excluded.japanese_opacity,
        page_margin = excluded.page_margin,
        reading_width = excluded.reading_width,
        column_layout = excluded.column_layout,
        orientation_preference = excluded.orientation_preference,
        text_selection_enabled = excluded.text_selection_enabled,
        tap_page_turn_enabled = excluded.tap_page_turn_enabled,
        theme_preference = excluded.theme_preference,
        notify_new_chapters = excluded.notify_new_chapters,
        cache_limit_bytes = excluded.cache_limit_bytes,
        updated_at_us = excluded.updated_at_us;
    ''',
      [
        reader.readingMode.name,
        reader.translationSource.name,
        reader.layoutMode.name,
        reader.palette.name,
        reader.fontFamily.name,
        _boolean(reader.bodyBold),
        reader.chineseFontSize,
        reader.japaneseFontSize,
        reader.lineHeight,
        reader.paragraphSpacing,
        reader.japaneseOpacity,
        reader.pageMargin,
        reader.readingWidth,
        reader.columnLayout.name,
        reader.orientationPreference.name,
        _boolean(reader.textSelectionEnabled),
        _boolean(reader.tapPageTurnEnabled),
        settings.themePreference.name,
        0,
        settings.cacheLimitBytes,
        _timestamp(settings.updatedAt),
      ],
    );
  }

  @override
  LocalAppSettings? appSettings() {
    _checkOpen();
    final rows = _database.select(
      'SELECT * FROM app_settings WHERE singleton_id = 1;',
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LocalAppSettings(
      readerSettings: ReaderSettings(
        readingMode: _enumValue(
          ReadingMode.values,
          row['reading_mode'],
          'reading_mode',
        ),
        translationSource: _enumValue(
          TranslationSource.values,
          row['translation_source'],
          'translation_source',
        ),
        layoutMode: _enumValue(
          ReaderLayoutMode.values,
          row['layout_mode'],
          'layout_mode',
        ),
        palette: _enumValue(
          ReaderPalette.values,
          row['reader_palette'],
          'reader_palette',
        ),
        fontFamily: _enumValue(
          ReaderFontFamily.values,
          row['font_family'],
          'font_family',
        ),
        bodyBold: _int(row['body_bold']) == 1,
        chineseFontSize: _double(row['chinese_font_size']),
        japaneseFontSize: _double(row['japanese_font_size']),
        lineHeight: _double(row['line_height']),
        paragraphSpacing: _double(row['paragraph_spacing']),
        japaneseOpacity: _double(row['japanese_opacity']),
        pageMargin: _double(row['page_margin']),
        readingWidth: _double(row['reading_width']),
        columnLayout: _enumValue(
          ReaderColumnLayout.values,
          row['column_layout'],
          'column_layout',
        ),
        orientationPreference: _enumValue(
          ReaderOrientationPreference.values,
          row['orientation_preference'],
          'orientation_preference',
        ),
        textSelectionEnabled: _int(row['text_selection_enabled']) == 1,
        tapPageTurnEnabled: _int(row['tap_page_turn_enabled']) == 1,
      ),
      themePreference: _enumValue(
        ThemePreference.values,
        row['theme_preference'],
        'theme_preference',
      ),
      cacheLimitBytes: _int(row['cache_limit_bytes']),
      updatedAt: _dateTime(row['updated_at_us']),
    );
  }

  void _upsertNovelOutline(CachedNovelOutline outline) {
    _database.execute(
      '''
      INSERT INTO cached_novels (
        id, chinese_title, japanese_title, author, content_source,
        publication_state, chapter_count, word_count, updated_at_us, tags_json,
        coverage_json, synopsis, points, views, original_url, fetched_at_us,
        record_revision, etag
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        chinese_title = excluded.chinese_title,
        japanese_title = excluded.japanese_title,
        author = excluded.author,
        content_source = excluded.content_source,
        publication_state = excluded.publication_state,
        chapter_count = excluded.chapter_count,
        word_count = excluded.word_count,
        updated_at_us = excluded.updated_at_us,
        tags_json = excluded.tags_json,
        coverage_json = excluded.coverage_json,
        fetched_at_us = excluded.fetched_at_us,
        record_revision = excluded.record_revision,
        etag = excluded.etag;
      ''',
      [
        outline.id,
        outline.chineseTitle,
        outline.japaneseTitle,
        outline.author,
        outline.contentSource,
        outline.publicationState.name,
        outline.chapterCount,
        outline.wordCount,
        outline.updatedAt == null ? null : _timestamp(outline.updatedAt!),
        jsonEncode(outline.tags),
        _encodeCoverage(outline.translationCoverage),
        _timestamp(outline.fetchedAt),
        outline.revision,
        outline.etag,
      ],
    );
  }

  CachedNovelOutline _outlineFromRow(Row row) {
    return CachedNovelOutline(
      id: _string(row['id']),
      chineseTitle: _string(row['chinese_title']),
      japaneseTitle: _string(row['japanese_title']),
      author: _string(row['author']),
      contentSource: _string(row['content_source']),
      publicationState: _enumValue(
        CachedNovelState.values,
        row['publication_state'],
        'publication_state',
      ),
      chapterCount: _nullableInt(row['chapter_count']),
      wordCount: _nullableInt(row['word_count']),
      updatedAt: _nullableDateTime(row['updated_at_us']),
      tags: _decodeStringList(row['tags_json'], 'tags_json'),
      translationCoverage: _decodeCoverage(row['coverage_json']),
      fetchedAt: _dateTime(row['fetched_at_us']),
      revision: row['record_revision'] as String?,
      etag: row['etag'] as String?,
    );
  }

  void _upsertChapterPayload(CachedChapterPayload payload) {
    final existing = _payloadById(payload.id);
    if (existing != null &&
        (existing.novelId != payload.novelId ||
            existing.chapterId != payload.chapterId ||
            existing.revision != payload.revision ||
            existing.etag != payload.etag)) {
      throw StateError('Chapter payload ${payload.id} identity cannot change.');
    }
    _database.execute(
      '''
      INSERT INTO cached_chapter_payloads (
        payload_id, novel_id, chapter_id, chapter_index, chinese_title,
        japanese_title, previous_chapter_id, next_chapter_id, published_at_us,
        japanese_blocks_json, translations_json, fetched_at_us,
        chapter_revision, etag
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(payload_id) DO UPDATE SET
        novel_id = excluded.novel_id,
        chapter_id = excluded.chapter_id,
        chapter_index = excluded.chapter_index,
        chinese_title = excluded.chinese_title,
        japanese_title = excluded.japanese_title,
        previous_chapter_id = excluded.previous_chapter_id,
        next_chapter_id = excluded.next_chapter_id,
        published_at_us = excluded.published_at_us,
        japanese_blocks_json = excluded.japanese_blocks_json,
        translations_json = excluded.translations_json,
        fetched_at_us = excluded.fetched_at_us,
        chapter_revision = excluded.chapter_revision,
        etag = excluded.etag;
      ''',
      [
        payload.id,
        payload.novelId,
        payload.chapterId,
        payload.index,
        payload.chineseTitle,
        payload.japaneseTitle,
        payload.previousChapterId,
        payload.nextChapterId,
        payload.publishedAt == null ? null : _timestamp(payload.publishedAt!),
        jsonEncode(payload.japaneseBlocks),
        _encodeTranslations(payload.translations),
        _timestamp(payload.fetchedAt),
        payload.revision,
        payload.etag,
      ],
    );
  }

  CachedChapterPayload? _payloadById(String payloadId) {
    final rows = _database.select(
      'SELECT * FROM cached_chapter_payloads WHERE payload_id = ?;',
      [payloadId],
    );
    return rows.isEmpty ? null : _payloadFromRow(rows.single);
  }

  CachedChapterPayload _payloadFromRow(Row row) {
    return CachedChapterPayload(
      id: _string(row['payload_id']),
      novelId: _string(row['novel_id']),
      chapterId: _string(row['chapter_id']),
      index: _int(row['chapter_index']),
      chineseTitle: _string(row['chinese_title']),
      japaneseTitle: _string(row['japanese_title']),
      previousChapterId: row['previous_chapter_id'] as String?,
      nextChapterId: row['next_chapter_id'] as String?,
      publishedAt: _nullableDateTime(row['published_at_us']),
      japaneseBlocks: _decodeStringList(
        row['japanese_blocks_json'],
        'japanese_blocks_json',
      ),
      translations: _decodeTranslations(row['translations_json']),
      fetchedAt: _dateTime(row['fetched_at_us']),
      revision: row['chapter_revision'] as String?,
      etag: row['etag'] as String?,
    );
  }

  void _validateCopyPayloadReference(OfflineChapterCopy copy) {
    final payloadId = copy.payloadId;
    if (payloadId == null) return;
    final payload = _payloadById(payloadId);
    if (payload == null) {
      throw StateError('Copy ${copy.id} references a missing chapter payload.');
    }
    _validatePayloadCopy(payload: payload, copy: copy, expectedKind: copy.kind);
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

  void _deletePayloadIfUnreferenced(String payloadId) {
    _database.execute(
      'DELETE FROM cached_chapter_payloads AS payload '
      'WHERE payload.payload_id = ? AND NOT EXISTS ('
      'SELECT 1 FROM offline_chapter_copies AS copy '
      'WHERE copy.payload_id = payload.payload_id);',
      [payloadId],
    );
  }

  static String _encodeCoverage(List<CachedTranslationCoverage> coverage) {
    final sorted = [...coverage]
      ..sort((a, b) => a.source.index.compareTo(b.source.index));
    return jsonEncode([
      for (final item in sorted)
        {
          'source': item.source.name,
          'translatedChapters': item.translatedChapters,
          'totalChapters': item.totalChapters,
        },
    ]);
  }

  static List<CachedTranslationCoverage> _decodeCoverage(Object? stored) {
    final decoded = _decodeJson(stored, 'coverage_json');
    if (decoded is! List<Object?>) {
      throw StateError('Invalid coverage_json structure.');
    }
    final coverage = <CachedTranslationCoverage>[];
    for (final item in decoded) {
      if (item is! Map<String, Object?>) {
        throw StateError('Invalid coverage_json item.');
      }
      coverage.add(
        CachedTranslationCoverage(
          source: _enumValue(
            TranslationSource.values,
            item['source'],
            'coverage source',
          ),
          translatedChapters: _nullableInt(item['translatedChapters']),
          totalChapters: _nullableInt(item['totalChapters']),
        ),
      );
    }
    return coverage;
  }

  static String _encodeTranslations(
    Map<TranslationSource, CachedChapterTranslation> translations,
  ) {
    final sources = translations.keys.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return jsonEncode({
      for (final source in sources)
        source.name: {
          'availability': translations[source]!.availability.name,
          'blocks': translations[source]!.blocks,
        },
    });
  }

  static Map<TranslationSource, CachedChapterTranslation> _decodeTranslations(
    Object? stored,
  ) {
    final decoded = _decodeJson(stored, 'translations_json');
    if (decoded is! Map<String, Object?>) {
      throw StateError('Invalid translations_json structure.');
    }
    final translations = <TranslationSource, CachedChapterTranslation>{};
    for (final entry in decoded.entries) {
      final source = _enumValue(
        TranslationSource.values,
        entry.key,
        'translation source',
      );
      final value = entry.value;
      if (value is! Map<String, Object?>) {
        throw StateError('Invalid translations_json item.');
      }
      translations[source] = CachedChapterTranslation(
        availability: _enumValue(
          TranslationAvailability.values,
          value['availability'],
          'translation availability',
        ),
        blocks: _stringList(value['blocks'], 'translations_json blocks'),
      );
    }
    return translations;
  }

  static List<String> _decodeStringList(Object? stored, String column) {
    return _stringList(_decodeJson(stored, column), column);
  }

  static List<String> _stringList(Object? decoded, String column) {
    if (decoded is! List<Object?> || decoded.any((item) => item is! String)) {
      throw StateError('Invalid $column string array.');
    }
    return decoded.cast<String>();
  }

  static Object? _decodeJson(Object? stored, String column) {
    try {
      return jsonDecode(_string(stored));
    } on FormatException {
      throw StateError('Corrupt JSON in $column.');
    }
  }

  void _insertTask(DownloadTask task) {
    _database.execute('''
      INSERT INTO download_tasks (
        id, intent_id, novel_id, chapter_id, translation_source, state,
        created_at_us, updated_at_us, task_revision, attempt_count,
        bytes_received, total_bytes, failure_kind, failure_message,
        failure_retryable, failure_required_bytes, failure_available_bytes,
        stored_copy_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''', _taskArguments(task));
  }

  void _updateTask(DownloadTask task) {
    _database.execute(
      '''
      UPDATE download_tasks SET
        intent_id = ?, novel_id = ?, chapter_id = ?, translation_source = ?,
        state = ?, created_at_us = ?, updated_at_us = ?, task_revision = ?,
        attempt_count = ?, bytes_received = ?, total_bytes = ?,
        failure_kind = ?, failure_message = ?, failure_retryable = ?,
        failure_required_bytes = ?, failure_available_bytes = ?,
        stored_copy_id = ?
      WHERE id = ?;
    ''',
      [..._taskArguments(task).skip(1), task.id],
    );
    if (_database.updatedRows != 1) {
      throw StateError('Task ${task.id} no longer exists.');
    }
  }

  List<Object?> _taskArguments(DownloadTask task) {
    return [
      task.id,
      task.intentId,
      task.novelId,
      task.chapterId,
      task.translationSource.name,
      task.state.name,
      _timestamp(task.createdAt),
      _timestamp(task.updatedAt),
      task.revision,
      task.attemptCount,
      task.bytesReceived,
      task.totalBytes,
      task.failure?.kind.name,
      task.failure?.message,
      task.failure == null ? null : _boolean(task.failure!.retryable),
      task.failure?.requiredBytes,
      task.failure?.availableBytes,
      task.storedCopyId,
    ];
  }

  DownloadTask _taskFromRow(Row row) {
    final failureKind = row['failure_kind'] as String?;
    return DownloadTask.restore(
      id: _string(row['id']),
      intentId: _string(row['intent_id']),
      novelId: _string(row['novel_id']),
      chapterId: _string(row['chapter_id']),
      translationSource: _enumValue(
        TranslationSource.values,
        row['translation_source'],
        'translation_source',
      ),
      state: _enumValue(DownloadTaskState.values, row['state'], 'state'),
      createdAt: _dateTime(row['created_at_us']),
      updatedAt: _dateTime(row['updated_at_us']),
      revision: _int(row['task_revision']),
      attemptCount: _int(row['attempt_count']),
      bytesReceived: _int(row['bytes_received']),
      totalBytes: _nullableInt(row['total_bytes']),
      failure: failureKind == null
          ? null
          : DownloadFailure(
              kind: _enumValue(
                DownloadFailureKind.values,
                failureKind,
                'failure_kind',
              ),
              message: _string(row['failure_message']),
              retryable: _int(row['failure_retryable']) == 1,
              requiredBytes: _nullableInt(row['failure_required_bytes']),
              availableBytes: _nullableInt(row['failure_available_bytes']),
            ),
      storedCopyId: row['stored_copy_id'] as String?,
    );
  }

  void _insertCopy(OfflineChapterCopy copy) {
    _database.execute('''
      INSERT INTO offline_chapter_copies (
        id, novel_id, chapter_id, copy_kind, translation_source,
        original_bytes, translation_bytes, stored_at_us, last_read_at_us,
        intent_id, payload_id, chapter_revision, etag
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''', _copyArguments(copy));
  }

  void _upsertCopy(OfflineChapterCopy copy) {
    _database.execute('''
      INSERT INTO offline_chapter_copies (
        id, novel_id, chapter_id, copy_kind, translation_source,
        original_bytes, translation_bytes, stored_at_us, last_read_at_us,
        intent_id, payload_id, chapter_revision, etag
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        novel_id = excluded.novel_id,
        chapter_id = excluded.chapter_id,
        copy_kind = excluded.copy_kind,
        translation_source = excluded.translation_source,
        original_bytes = excluded.original_bytes,
        translation_bytes = excluded.translation_bytes,
        stored_at_us = excluded.stored_at_us,
        last_read_at_us = excluded.last_read_at_us,
        intent_id = excluded.intent_id,
        payload_id = excluded.payload_id,
        chapter_revision = excluded.chapter_revision,
        etag = excluded.etag;
    ''', _copyArguments(copy));
  }

  List<Object?> _copyArguments(OfflineChapterCopy copy) {
    return [
      copy.id,
      copy.novelId,
      copy.chapterId,
      copy.kind.name,
      copy.translationSource.name,
      copy.originalBytes,
      copy.translationBytes,
      _timestamp(copy.storedAt),
      _timestamp(copy.lastReadAt),
      copy.intentId,
      copy.payloadId,
      copy.revision,
      copy.etag,
    ];
  }

  OfflineChapterCopy _copyFromRow(Row row) {
    return OfflineChapterCopy(
      id: _string(row['id']),
      novelId: _string(row['novel_id']),
      chapterId: _string(row['chapter_id']),
      kind: _enumValue(OfflineCopyKind.values, row['copy_kind'], 'copy_kind'),
      translationSource: _enumValue(
        TranslationSource.values,
        row['translation_source'],
        'translation_source',
      ),
      originalBytes: _int(row['original_bytes']),
      translationBytes: _nullableInt(row['translation_bytes']),
      storedAt: _dateTime(row['stored_at_us']),
      lastReadAt: _dateTime(row['last_read_at_us']),
      intentId: row['intent_id'] as String?,
      payloadId: row['payload_id'] as String?,
      revision: row['chapter_revision'] as String?,
      etag: row['etag'] as String?,
    );
  }

  DownloadIntent _intentFromRow(Row row) {
    final commonSource = _enumValue(
      TranslationSource.values,
      row['translation_source'],
      'translation_source',
    );
    return switch (_string(row['intent_kind'])) {
      'chapter' => ChapterDownloadIntent(
        id: _string(row['id']),
        novelId: _string(row['novel_id']),
        chapterId: _string(row['chapter_id']),
        translationSource: commonSource,
        createdAt: _dateTime(row['created_at_us']),
        enabled: _int(row['enabled']) == 1,
      ),
      'novel' => NovelDownloadIntent(
        id: _string(row['id']),
        novelId: _string(row['novel_id']),
        translationSource: commonSource,
        createdAt: _dateTime(row['created_at_us']),
        enabled: _int(row['enabled']) == 1,
      ),
      final kind => throw StateError('Unknown persisted intent kind $kind.'),
    };
  }

  LocalReadingProgress _progressFromRow(Row row) {
    return LocalReadingProgress(
      novelId: _string(row['novel_id']),
      position: ReadingPosition(
        chapterId: _string(row['chapter_id']),
        blockId: _string(row['block_id']),
        intraBlockOffset: _int(row['intra_block_offset']),
      ),
      updatedAt: _dateTime(row['updated_at_us']),
    );
  }

  LocalBookmark _bookmarkFromRow(Row row) {
    return LocalBookmark(
      id: _string(row['id']),
      novelId: _string(row['novel_id']),
      position: ReadingPosition(
        chapterId: _string(row['chapter_id']),
        blockId: _string(row['block_id']),
        intraBlockOffset: _int(row['intra_block_offset']),
      ),
      createdAt: _dateTime(row['created_at_us']),
    );
  }

  DownloadIntent _requireIntent(String id) {
    final intent = intentById(id);
    if (intent == null) throw StateError('Unknown download intent $id.');
    return intent;
  }

  void _writeIntentEnabled(DownloadIntent intent) {
    _database.execute('UPDATE download_intents SET enabled = ? WHERE id = ?;', [
      _boolean(intent.enabled),
      intent.id,
    ]);
    if (_database.updatedRows != 1) {
      throw StateError('Download intent ${intent.id} no longer exists.');
    }
  }

  T _transaction<T>(T Function() action) {
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      _database.execute('COMMIT;');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('SQLite repository is closed.');
  }

  static void _validatePosition(String novelId, ReadingPosition position) {
    if (novelId.isEmpty ||
        position.chapterId.isEmpty ||
        position.blockId.isEmpty ||
        position.intraBlockOffset < 0) {
      throw ArgumentError(
        'Reading position fields must be valid and nonempty.',
      );
    }
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

  static T _enumValue<T extends Enum>(
    List<T> values,
    Object? stored,
    String column,
  ) {
    final name = _string(stored);
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw StateError('Unknown $column value $name.');
  }

  static int _timestamp(DateTime value) => value.microsecondsSinceEpoch;

  static DateTime _dateTime(Object? value) {
    return DateTime.fromMicrosecondsSinceEpoch(_int(value), isUtc: true);
  }

  static DateTime? _nullableDateTime(Object? value) {
    return value == null ? null : _dateTime(value);
  }

  static int _boolean(bool value) => value ? 1 : 0;

  static String _string(Object? value) {
    if (value is String) return value;
    throw StateError('Expected persisted text, found $value.');
  }

  static int _int(Object? value) {
    if (value is int) return value;
    throw StateError('Expected persisted integer, found $value.');
  }

  static int? _nullableInt(Object? value) => value == null ? null : _int(value);

  static double _double(Object? value) {
    if (value is num) return value.toDouble();
    throw StateError('Expected persisted number, found $value.');
  }
}
