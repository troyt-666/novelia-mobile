import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Owns SQLite opening and forward-only schema migration.
final class NoveliaDatabase {
  NoveliaDatabase._();

  static const int currentSchemaVersion = 4;
  static const String defaultFileName = 'novelia-reader.sqlite3';

  static Future<Database> openApplicationSupport({
    String fileName = defaultFileName,
  }) async {
    if (fileName.isEmpty || p.basename(fileName) != fileName) {
      throw ArgumentError.value(
        fileName,
        'fileName',
        'Use a plain database file name without path components.',
      );
    }
    final supportDirectory = await getApplicationSupportDirectory();
    await supportDirectory.create(recursive: true);
    return openFile(p.join(supportDirectory.path, fileName));
  }

  static Database openFile(String filePath) {
    if (filePath.isEmpty) throw ArgumentError.value(filePath, 'filePath');
    Directory(p.dirname(filePath)).createSync(recursive: true);
    final database = sqlite3.open(filePath);
    try {
      initialize(database);
      database.execute('PRAGMA journal_mode = WAL;');
      return database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static Database openInMemory() {
    final database = sqlite3.openInMemory();
    try {
      initialize(database);
      return database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  /// Initializes an already-open connection, including migrating older data.
  static void initialize(Database database) {
    database.execute('PRAGMA foreign_keys = ON;');
    database.execute('PRAGMA busy_timeout = 5000;');

    final existingVersion = database.userVersion;
    if (existingVersion > currentSchemaVersion) {
      throw StateError(
        'Database schema $existingVersion is newer than supported schema '
        '$currentSchemaVersion.',
      );
    }

    if (existingVersion == 0) {
      _transaction(database, () {
        _createVersion1(database);
        database.userVersion = 1;
      });
    }
    if (database.userVersion == 1) {
      _transaction(database, () {
        _migrateVersion1To2(database);
        database.userVersion = 2;
      });
    }
    if (database.userVersion == 2) {
      _transaction(database, () {
        _migrateVersion2To3(database);
        database.userVersion = 3;
      });
    }
    if (database.userVersion == 3) {
      _transaction(database, () {
        _migrateVersion3To4(database);
        database.userVersion = 4;
      });
    }
  }

  static void _createVersion1(Database database) {
    database.execute('''
      CREATE TABLE download_intents (
        id TEXT NOT NULL PRIMARY KEY,
        novel_id TEXT NOT NULL,
        intent_kind TEXT NOT NULL CHECK (intent_kind IN ('chapter', 'novel')),
        chapter_id TEXT,
        translation_source TEXT NOT NULL,
        created_at_us INTEGER NOT NULL,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        CHECK (
          (intent_kind = 'chapter' AND chapter_id IS NOT NULL) OR
          (intent_kind = 'novel' AND chapter_id IS NULL)
        )
      );

      CREATE TABLE download_tasks (
        id TEXT NOT NULL PRIMARY KEY,
        intent_id TEXT NOT NULL,
        novel_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        translation_source TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at_us INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL,
        task_revision INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL,
        bytes_received INTEGER NOT NULL,
        total_bytes INTEGER,
        failure_kind TEXT,
        failure_message TEXT,
        failure_retryable INTEGER,
        failure_required_bytes INTEGER,
        failure_available_bytes INTEGER,
        stored_copy_id TEXT
      );

      CREATE INDEX download_tasks_intent_idx
        ON download_tasks (intent_id, id);
      CREATE INDEX download_tasks_novel_idx
        ON download_tasks (novel_id, translation_source, id);

      CREATE TABLE offline_chapter_copies (
        id TEXT NOT NULL PRIMARY KEY,
        novel_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        copy_kind TEXT NOT NULL CHECK (copy_kind IN ('cacheCopy', 'offlineDownload')),
        translation_source TEXT NOT NULL,
        original_bytes INTEGER NOT NULL,
        translation_bytes INTEGER,
        stored_at_us INTEGER NOT NULL,
        last_read_at_us INTEGER NOT NULL,
        intent_id TEXT,
        chapter_revision TEXT,
        etag TEXT,
        CHECK (
          (copy_kind = 'cacheCopy' AND intent_id IS NULL) OR
          (copy_kind = 'offlineDownload' AND intent_id IS NOT NULL)
        )
      );

      CREATE INDEX offline_copies_novel_idx
        ON offline_chapter_copies (novel_id, copy_kind, id);
      CREATE INDEX offline_copies_lru_idx
        ON offline_chapter_copies (copy_kind, last_read_at_us, stored_at_us, id);
    ''');
  }

  static void _migrateVersion1To2(Database database) {
    database.execute('''
      CREATE TABLE reading_progress (
        novel_id TEXT NOT NULL PRIMARY KEY,
        chapter_id TEXT NOT NULL,
        block_id TEXT NOT NULL,
        intra_block_offset INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL
      );

      CREATE TABLE bookmarks (
        id TEXT NOT NULL PRIMARY KEY,
        novel_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        block_id TEXT NOT NULL,
        intra_block_offset INTEGER NOT NULL,
        created_at_us INTEGER NOT NULL
      );

      CREATE INDEX bookmarks_novel_idx
        ON bookmarks (novel_id, created_at_us, id);

      CREATE TABLE last_route_state (
        singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
        route_name TEXT NOT NULL,
        novel_id TEXT,
        chapter_id TEXT,
        block_id TEXT,
        intra_block_offset INTEGER,
        updated_at_us INTEGER NOT NULL
      );

      CREATE TABLE app_settings (
        singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
        reading_mode TEXT NOT NULL,
        translation_source TEXT NOT NULL,
        chinese_font_size REAL NOT NULL,
        japanese_font_size REAL NOT NULL,
        line_height REAL NOT NULL,
        japanese_opacity REAL NOT NULL,
        reading_width REAL NOT NULL,
        theme_preference TEXT NOT NULL,
        notify_new_chapters INTEGER NOT NULL CHECK (notify_new_chapters IN (0, 1)),
        cache_limit_bytes INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL
      );
    ''');
  }

  static void _migrateVersion2To3(Database database) {
    database.execute('''
      CREATE TABLE recent_searches (
        query TEXT NOT NULL PRIMARY KEY,
        display_order INTEGER NOT NULL UNIQUE CHECK (display_order >= 0),
        updated_at_us INTEGER NOT NULL
      );
    ''');
  }

  static void _migrateVersion3To4(Database database) {
    database.execute('''
      ALTER TABLE offline_chapter_copies ADD COLUMN payload_id TEXT;

      CREATE INDEX offline_copies_payload_idx
        ON offline_chapter_copies (payload_id);

      CREATE TABLE cached_novels (
        id TEXT NOT NULL PRIMARY KEY,
        chinese_title TEXT NOT NULL,
        japanese_title TEXT NOT NULL,
        author TEXT NOT NULL,
        content_source TEXT NOT NULL,
        publication_state TEXT NOT NULL,
        chapter_count INTEGER,
        word_count INTEGER,
        updated_at_us INTEGER,
        tags_json TEXT NOT NULL,
        coverage_json TEXT NOT NULL,
        synopsis TEXT,
        points INTEGER,
        views INTEGER,
        original_url TEXT,
        fetched_at_us INTEGER NOT NULL,
        record_revision TEXT,
        etag TEXT
      );

      CREATE INDEX cached_novels_fetched_idx
        ON cached_novels (fetched_at_us DESC, id);

      CREATE TABLE cached_toc_sections (
        novel_id TEXT NOT NULL,
        section_id TEXT NOT NULL,
        section_order INTEGER NOT NULL,
        title TEXT NOT NULL,
        PRIMARY KEY (novel_id, section_id),
        UNIQUE (novel_id, section_order),
        FOREIGN KEY (novel_id) REFERENCES cached_novels (id) ON DELETE CASCADE
      );

      CREATE TABLE cached_toc_chapters (
        novel_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        section_id TEXT NOT NULL,
        chapter_order INTEGER NOT NULL,
        chapter_index INTEGER NOT NULL,
        chinese_title TEXT NOT NULL,
        japanese_title TEXT NOT NULL,
        published_at_us INTEGER,
        PRIMARY KEY (novel_id, chapter_id),
        UNIQUE (novel_id, section_id, chapter_order),
        FOREIGN KEY (novel_id, section_id)
          REFERENCES cached_toc_sections (novel_id, section_id)
          ON DELETE CASCADE
      );

      CREATE INDEX cached_toc_order_idx
        ON cached_toc_chapters (novel_id, section_id, chapter_order);

      CREATE TABLE cached_chapter_payloads (
        payload_id TEXT NOT NULL PRIMARY KEY,
        novel_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        chapter_index INTEGER NOT NULL,
        chinese_title TEXT NOT NULL,
        japanese_title TEXT NOT NULL,
        previous_chapter_id TEXT,
        next_chapter_id TEXT,
        published_at_us INTEGER,
        japanese_blocks_json TEXT NOT NULL,
        translations_json TEXT NOT NULL,
        fetched_at_us INTEGER NOT NULL,
        chapter_revision TEXT,
        etag TEXT
      );

      CREATE INDEX cached_payload_chapter_idx
        ON cached_chapter_payloads
          (novel_id, chapter_id, fetched_at_us DESC, payload_id DESC);
      CREATE INDEX cached_payload_novel_idx
        ON cached_chapter_payloads
          (novel_id, chapter_index, fetched_at_us DESC, payload_id DESC);
    ''');
  }

  static T _transaction<T>(Database database, T Function() action) {
    database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      database.execute('COMMIT;');
      return result;
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }
}
