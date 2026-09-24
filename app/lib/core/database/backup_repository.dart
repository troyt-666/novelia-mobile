part of 'sqlite_offline_repository.dart';

extension ReaderBackupRepository on SqliteOfflineRepository {
  ReaderBackup exportBackup({bool includeContent = false, DateTime? now}) {
    _checkOpen();
    return _transaction(() {
      final tables = <String, List<Map<String, Object?>>>{};
      for (final table in ReaderBackup.tableNames) {
        final where = switch (table) {
          'cached_chapter_payloads' =>
            includeContent
                ? " WHERE payload_id IN (SELECT payload_id FROM offline_chapter_copies WHERE copy_kind = 'offlineDownload')"
                : ' WHERE 0',
          'offline_chapter_copies' =>
            includeContent
                ? " WHERE copy_kind = 'offlineDownload' AND payload_id IS NOT NULL"
                : ' WHERE 0',
          _ => '',
        };
        tables[table] = _database
            .select('SELECT * FROM $table$where ORDER BY rowid;')
            .map((row) => Map<String, Object?>.from(row))
            .toList();
      }
      final ids = <Object?>{
        for (final table in [
          'reading_progress',
          'bookmarks',
          'download_intents',
        ])
          ...tables[table]!.map((row) => row['novel_id']),
      };
      tables['cached_novels']!.removeWhere((row) => !ids.contains(row['id']));
      // Old installations can have records whose metadata was evicted. Keep
      // those records discoverable on the receiving bookshelf as well.
      final outlinedIds = tables['cached_novels']!
          .map((row) => row['id'])
          .toSet();
      for (final id in ids.difference(outlinedIds)) {
        tables['cached_novels']!.add(
          _backupPlaceholderNovel(id as String, now ?? DateTime.now()),
        );
      }
      for (final table in ['cached_toc_sections', 'cached_toc_chapters']) {
        tables[table]!.removeWhere((row) => !ids.contains(row['novel_id']));
      }
      return ReaderBackup(
        createdAt: now ?? DateTime.now(),
        includesContent: includeContent,
        tables: tables,
      );
    });
  }

  /// Parses into a separate database first. No incoming SQL or file path runs.
  SqliteOfflineRepository _stageBackup(ReaderBackup backup) {
    final stage = SqliteOfflineRepository.openInMemory();
    try {
      if (backup.tables.values.fold<int>(0, (n, rows) => n + rows.length) >
              250000 ||
          backup.createdAt.microsecondsSinceEpoch < 0) {
        throw const FormatException('Invalid backup size or time');
      }
      if (backup.tables.keys
              .toSet()
              .difference(ReaderBackup.tableNames.toSet())
              .isNotEmpty ||
          backup.tables.length != ReaderBackup.tableNames.length) {
        throw const FormatException('Unexpected tables');
      }
      for (final table in ReaderBackup.tableNames) {
        final columns = stage._database.select('PRAGMA table_info($table);');
        final names = columns.map((c) => c['name'] as String).toSet();
        for (final rawRow in backup.rows(table)) {
          final row = <String, Object?>{...rawRow};
          if (table == 'cached_chapter_payloads' &&
              !row.containsKey('illustrations_json')) {
            row['illustrations_json'] = '{}';
            row['illustrations_complete'] =
                (row['japanese_blocks_json'] as String).contains('<图片>')
                ? 0
                : 1;
          }
          if (row.length != names.length || !names.containsAll(row.keys)) {
            throw const FormatException('Unexpected columns');
          }
          for (final column in columns) {
            final key = column['name'] as String;
            final value = row[key];
            if (value == null) {
              if (column['notnull'] == 1) {
                throw const FormatException('Missing field');
              }
            } else {
              final valid = switch (column['type']) {
                'TEXT' => value is String,
                'INTEGER' => value is int,
                'REAL' => value is num && value.isFinite,
                _ => false,
              };
              if (!valid) throw const FormatException('Invalid field type');
              if (key.endsWith('_us') &&
                  (value is! int || value < 0 || value > 8640000000000000000)) {
                throw const FormatException('Invalid timestamp');
              }
            }
          }
          _insertBackupRow(stage._database, table, row);
        }
      }
      for (final progress in stage.listReadingProgress()) {
        SqliteOfflineRepository._validatePosition(
          progress.novelId,
          progress.position,
        );
      }
      for (final bookmark in stage.listBookmarks()) {
        SqliteOfflineRepository._validatePosition(
          bookmark.novelId,
          bookmark.position,
        );
        if (bookmark.id.isEmpty) {
          throw const FormatException('Empty bookmark ID');
        }
      }
      final settings = stage.appSettings()?.readerSettings;
      if (settings != null &&
          (settings.chineseFontSize <= 0 ||
              settings.chineseFontSize > 200 ||
              settings.japaneseFontSize <= 0 ||
              settings.japaneseFontSize > 200 ||
              settings.lineHeight <= 0 ||
              settings.lineHeight > 10 ||
              settings.paragraphSpacing < 0 ||
              settings.paragraphSpacing > 500 ||
              settings.pageMargin < 0 ||
              settings.pageMargin > 500 ||
              settings.readingWidth <= 0 ||
              settings.readingWidth > 10000 ||
              settings.japaneseOpacity < 0 ||
              settings.japaneseOpacity > 1)) {
        throw const FormatException('Invalid reader settings');
      }
      for (final novel in stage.listCachedNovels()) {
        stage.novelDetail(novel.id);
      }
      for (final intent in stage.listIntents()) {
        if (intent.id.isEmpty ||
            intent.novelId.isEmpty ||
            (intent is ChapterDownloadIntent && intent.chapterId.isEmpty)) {
          throw const FormatException('Invalid download intent');
        }
      }
      for (final copy in stage.listCopies()) {
        final intent = stage.intentById(copy.intentId ?? '');
        if (copy.kind != OfflineCopyKind.offlineDownload ||
            copy.payloadId == null ||
            intent == null ||
            intent.novelId != copy.novelId ||
            intent.translationSource != copy.translationSource ||
            (intent is ChapterDownloadIntent &&
                intent.chapterId != copy.chapterId)) {
          throw const FormatException('Invalid offline reference');
        }
        stage._validateCopyPayloadReference(copy);
      }
      for (final row in backup.rows('cached_chapter_payloads')) {
        final payload = stage.chapterPayloadById(row['payload_id'] as String)!;
        stage._database.execute(
          'UPDATE cached_chapter_payloads SET illustrations_complete = ? WHERE payload_id = ?;',
          [payload.illustrationsComplete ? 1 : 0, payload.id],
        );
      }
      if (!backup.includesContent &&
          (stage.listCopies().isNotEmpty ||
              backup.rows('cached_chapter_payloads').isNotEmpty)) {
        throw const FormatException('Unexpected content');
      }
      if (stage._database.select('PRAGMA foreign_key_check;').isNotEmpty) {
        throw const FormatException('Invalid relations');
      }
      return stage;
    } on Object {
      stage.close();
      throw const BackupException('备份数据不完整或包含无效记录，未导入任何数据。');
    }
  }

  String _backupFingerprint() => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            for (final table in [
              ...ReaderBackup.tableNames.where(
                (t) => t != 'cached_chapter_payloads',
              ),
              'download_tasks',
            ])
              table: _database
                  .select('SELECT * FROM $table ORDER BY rowid;')
                  .map((row) => Map.of(row))
                  .toList(),
          }),
        ),
      )
      .toString();

  BackupPreview previewBackup(ReaderBackup backup) {
    _checkOpen();
    final stage = _stageBackup(backup);
    try {
      final localProgress = {
        for (final p in listReadingProgress()) p.novelId: p,
      };
      final bookmarks = {
        for (final b in listBookmarks()) _positionKey(b.novelId, b.position),
      };
      final copies = {
        for (final c in listCopies(kind: OfflineCopyKind.offlineDownload))
          _copyKey(c),
      };
      final novels = {for (final n in listCachedNovels()) n.id};
      final conflicts = <ProgressConflict>[];
      for (final incoming in stage.listReadingProgress()) {
        final local = localProgress[incoming.novelId];
        if (local == null || local.position == incoming.position) continue;
        final detail =
            stage.novelDetail(incoming.novelId) ??
            novelDetail(incoming.novelId);
        final title = stage.cachedNovelOutline(incoming.novelId)?.chineseTitle;
        conflicts.add(
          ProgressConflict(
            novelId: incoming.novelId,
            title: title == null || title.isEmpty ? incoming.novelId : title,
            localPosition: _positionLabel(
              local.position,
              novelDetail(incoming.novelId) ?? detail,
            ),
            importedPosition: _positionLabel(incoming.position, detail),
            localTime: local.updatedAt,
            importedTime: incoming.updatedAt,
          ),
        );
      }
      return BackupPreview(
        backup: backup,
        localFingerprint: _backupFingerprint(),
        conflicts: conflicts,
        newNovels: stage
            .listCachedNovels()
            .where((n) => !novels.contains(n.id))
            .length,
        newDownloads: stage
            .listIntents()
            .map(_intentKey)
            .toSet()
            .difference(listIntents().map(_intentKey).toSet())
            .length,
        newProgress: stage
            .listReadingProgress()
            .where((p) => !localProgress.containsKey(p.novelId))
            .length,
        newBookmarks: stage
            .listBookmarks()
            .map((b) => _positionKey(b.novelId, b.position))
            .toSet()
            .difference(bookmarks)
            .length,
        newChapters: stage
            .listCopies()
            .map(_copyKey)
            .toSet()
            .difference(copies)
            .length,
      );
    } finally {
      stage.close();
    }
  }

  BackupMergeResult mergeBackup(
    BackupPreview preview, {
    Map<String, ProgressChoice> choices = const {},
    bool importSettings = false,
  }) {
    _checkOpen();
    final stage = _stageBackup(preview.backup);
    try {
      return _transaction(() {
        if (_backupFingerprint() != preview.localFingerprint) {
          throw const BackupException('本机数据已变化，请重新预览后再合并。');
        }
        var newNovels = 0,
            progressUpdated = 0,
            bookmarksAdded = 0,
            chaptersAdded = 0;
        // Keep local metadata and catalogs; append missing identities. A newer
        // catalog may have removed chapters still referenced by local records.
        for (final row in preview.backup.rows('cached_novels')) {
          if (cachedNovelOutline(row['id'] as String) == null) {
            _insertBackupRow(_database, 'cached_novels', row);
            newNovels++;
          }
        }
        for (final row in preview.backup.rows('cached_toc_sections')) {
          if (_database.select(
            'SELECT 1 FROM cached_toc_sections WHERE novel_id=? AND section_id=?;',
            [row['novel_id'], row['section_id']],
          ).isNotEmpty) {
            continue;
          }
          final order = _database.select(
            'SELECT COALESCE(MAX(section_order), -1)+1 AS n FROM cached_toc_sections WHERE novel_id=?;',
            [row['novel_id']],
          ).single['n'];
          _insertBackupRow(_database, 'cached_toc_sections', {
            ...row,
            'section_order': order,
          });
        }
        for (final row in preview.backup.rows('cached_toc_chapters')) {
          if (_database.select(
            'SELECT 1 FROM cached_toc_chapters WHERE novel_id=? AND chapter_id=?;',
            [row['novel_id'], row['chapter_id']],
          ).isNotEmpty) {
            continue;
          }
          final order = _database.select(
            'SELECT COALESCE(MAX(chapter_order), -1)+1 AS n FROM cached_toc_chapters WHERE novel_id=? AND section_id=?;',
            [row['novel_id'], row['section_id']],
          ).single['n'];
          _insertBackupRow(_database, 'cached_toc_chapters', {
            ...row,
            'chapter_order': order,
          });
        }
        final positions = {
          for (final b in listBookmarks()) _positionKey(b.novelId, b.position),
        };
        void addBookmark(
          String novelId,
          ReadingPosition position,
          DateTime createdAt,
        ) {
          final key = _positionKey(novelId, position);
          if (!positions.add(key)) return;
          // Content identity also protects against UUID reuse across backups.
          var id = 'backup-${sha256.convert(utf8.encode(key))}';
          while (_database.select('SELECT 1 FROM bookmarks WHERE id=?;', [
            id,
          ]).isNotEmpty) {
            id = '$id-1';
          }
          saveBookmark(
            LocalBookmark(
              id: id,
              novelId: novelId,
              position: position,
              createdAt: createdAt,
            ),
          );
          bookmarksAdded++;
        }

        for (final bookmark in stage.listBookmarks()) {
          addBookmark(bookmark.novelId, bookmark.position, bookmark.createdAt);
        }
        for (final incoming in stage.listReadingProgress()) {
          final local = readingProgressFor(incoming.novelId);
          if (local == null) {
            saveReadingProgress(incoming);
            progressUpdated++;
            continue;
          }
          if (local.position == incoming.position) {
            if (incoming.updatedAt.isAfter(local.updatedAt)) {
              saveReadingProgress(incoming);
              progressUpdated++;
            }
            continue;
          }
          final useImported =
              (choices[incoming.novelId] ??
                  (incoming.updatedAt.isAfter(local.updatedAt)
                      ? ProgressChoice.imported
                      : ProgressChoice.local)) ==
              ProgressChoice.imported;
          final retained = useImported ? local : incoming;
          addBookmark(retained.novelId, retained.position, retained.updatedAt);
          if (useImported) {
            saveReadingProgress(incoming);
            progressUpdated++;
          }
        }
        final intentMap = <String, String>{};
        final addedIntents = <String>{};
        final intentRows = {
          for (final row in preview.backup.rows('download_intents'))
            row['id']: row,
        };
        final payloadRows = {
          for (final row in stage._database.select(
            'SELECT * FROM cached_chapter_payloads;',
          ))
            row['payload_id']: row,
        };
        final semanticIntents = {
          for (final intent in listIntents()) _intentKey(intent): intent.id,
        };
        for (final intent in stage.listIntents()) {
          final key = _intentKey(intent);
          var id = semanticIntents[key];
          if (id == null) {
            id = intent.id;
            if (intentById(id) != null) {
              id = 'backup-intent-${sha256.convert(utf8.encode(key))}';
            }
            if (intentById(id) != null) {
              throw const BackupException('下载记录标识冲突，未导入任何数据。');
            }
            final row = intentRows[intent.id]!;
            _insertBackupRow(_database, 'download_intents', {
              ...row,
              'id': id,
              'enabled': 0,
            });
            semanticIntents[key] = id;
            addedIntents.add(id);
          }
          intentMap[intent.id] = id;
        }
        final existingCopies = {
          for (final c in listCopies(kind: OfflineCopyKind.offlineDownload))
            _copyKey(c),
        };
        for (final copy in stage.listCopies()) {
          final key = _copyKey(copy);
          if (!existingCopies.add(key)) continue;
          final payload = stage.chapterPayloadById(copy.payloadId!)!;
          final payloadRow = payloadRows[payload.id]!;
          // Namespaced by all content, not the exporting installation's ID.
          final payloadId =
              'backup-payload-${sha256.convert(utf8.encode(jsonEncode(payloadRow)))}';
          if (_payloadById(payloadId) == null) {
            _insertBackupRow(_database, 'cached_chapter_payloads', {
              ...payloadRow,
              'payload_id': payloadId,
            });
          }
          var copyId = 'backup-copy-${sha256.convert(utf8.encode(key))}';
          while (_copyById(copyId) != null) {
            copyId = '$copyId-1';
          }
          final intentId = intentMap[copy.intentId]!;
          final importedCopy = OfflineChapterCopy(
            id: copyId,
            novelId: copy.novelId,
            chapterId: copy.chapterId,
            kind: OfflineCopyKind.offlineDownload,
            translationSource: copy.translationSource,
            originalBytes: copy.originalBytes,
            translationBytes: copy.translationBytes,
            storedAt: copy.storedAt,
            lastReadAt: copy.lastReadAt,
            intentId: intentId,
            payloadId: payloadId,
            revision: copy.revision,
            etag: copy.etag,
          );
          _insertCopy(importedCopy);
          final taskId = SqliteOfflineRepository._taskId(
            intentId: intentId,
            chapterId: copy.chapterId,
            sourceName: copy.translationSource.name,
          );
          final oldTask = _taskById(taskId);
          final taskRow = <String, Object?>{
            'id': taskId,
            'intent_id': intentId,
            'novel_id': copy.novelId,
            'chapter_id': copy.chapterId,
            'translation_source': copy.translationSource.name,
            'state': 'stored',
            'created_at_us': copy.storedAt.microsecondsSinceEpoch,
            'updated_at_us': copy.storedAt.microsecondsSinceEpoch,
            'task_revision': (oldTask?.revision ?? 0) + 1,
            'attempt_count': 0,
            'bytes_received': copy.totalBytes,
            'total_bytes': copy.totalBytes,
            'failure_kind': null,
            'failure_message': null,
            'failure_retryable': null,
            'failure_required_bytes': null,
            'failure_available_bytes': null,
            'stored_copy_id': copyId,
          };
          if (oldTask != null) {
            _database.execute('DELETE FROM download_tasks WHERE id=?;', [
              taskId,
            ]);
          }
          _insertBackupRow(_database, 'download_tasks', taskRow);
          chaptersAdded++;
        }
        // Records-only restores still need visible, resumable task rows.
        for (final id in addedIntents) {
          final intent = intentById(id)!;
          final chapters = intent is ChapterDownloadIntent
              ? [intent.chapterId]
              : novelDetail(
                      intent.novelId,
                    )?.sections.expand((s) => s.chapters).map((c) => c.id) ??
                    const <String>[];
          for (final chapterId in chapters) {
            final taskId = SqliteOfflineRepository._taskId(
              intentId: id,
              chapterId: chapterId,
              sourceName: intent.translationSource.name,
            );
            if (_taskById(taskId) != null) continue;
            _insertTask(
              DownloadTask.queued(
                id: taskId,
                intentId: id,
                novelId: intent.novelId,
                chapterId: chapterId,
                translationSource: intent.translationSource,
                now: intent.createdAt,
              ).pause(intent.createdAt),
            );
          }
        }
        if (importSettings) {
          final settings = stage.appSettings();
          if (settings != null) saveAppSettings(settings);
        }
        final searches = <String>{
          ...recentSearches(),
          ...stage.recentSearches(),
        }.take(8).toList();
        // Preserve current search priority; importing never invents read events
        // or queues them for whichever account happens to be logged in.
        _database.execute('DELETE FROM recent_searches;');
        for (var i = 0; i < searches.length; i++) {
          _database.execute(
            'INSERT INTO recent_searches (query,display_order,updated_at_us) VALUES (?,?,?);',
            [searches[i], i, preview.backup.createdAt.microsecondsSinceEpoch],
          );
        }
        return BackupMergeResult(
          newNovels: newNovels,
          progressUpdated: progressUpdated,
          bookmarksAdded: bookmarksAdded,
          chaptersAdded: chaptersAdded,
          downloadsAdded: addedIntents.length,
        );
      });
    } finally {
      stage.close();
    }
  }
}

void _insertBackupRow(
  Database database,
  String table,
  Map<String, Object?> row,
) {
  // Only internal callers with allowlisted table/column names reach here.
  database.execute(
    'INSERT INTO $table (${row.keys.join(',')}) VALUES (${List.filled(row.length, '?').join(',')});',
    row.values.toList(),
  );
}

String _positionKey(String novelId, ReadingPosition p) =>
    jsonEncode([novelId, p.chapterId, p.blockId, p.intraBlockOffset]);
String _copyKey(OfflineChapterCopy c) =>
    jsonEncode([c.novelId, c.chapterId, c.translationSource.name]);
String _intentKey(DownloadIntent i) => jsonEncode([
  i.novelId,
  i is NovelDownloadIntent ? 'novel' : 'chapter',
  i is ChapterDownloadIntent ? i.chapterId : null,
  i.translationSource.name,
]);
String _positionLabel(ReadingPosition p, CachedNovelDetail? detail) {
  final chapter = detail?.sections
      .expand((s) => s.chapters)
      .where((c) => c.id == p.chapterId)
      .firstOrNull;
  final title = chapter == null
      ? '章节 ${p.chapterId}'
      : chapter.chineseTitle.isEmpty
      ? chapter.japaneseTitle
      : chapter.chineseTitle;
  final paragraph = RegExp(r'(\d+)$').firstMatch(p.blockId)?.group(1);
  return paragraph == null
      ? '$title · 已保存段落位置'
      : '$title · 第 ${int.parse(paragraph) + 1} 段附近';
}

Map<String, Object?> _backupPlaceholderNovel(String id, DateTime now) => {
  'id': id,
  'chinese_title': id,
  'japanese_title': '',
  'author': '',
  'content_source': id.split('/').first,
  'publication_state': 'unknown',
  'chapter_count': null,
  'word_count': null,
  'updated_at_us': null,
  'tags_json': '[]',
  'coverage_json': '[]',
  'synopsis': null,
  'points': null,
  'views': null,
  'original_url': null,
  'fetched_at_us': now.microsecondsSinceEpoch,
  'record_revision': null,
  'etag': null,
};
