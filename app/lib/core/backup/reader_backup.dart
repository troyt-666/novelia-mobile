import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A portable logical snapshot. It never contains SQL, login credentials,
/// remote-account state, transient download tasks, or a process restore route.
class ReaderBackup {
  ReaderBackup({
    required this.createdAt,
    required this.includesContent,
    required Map<String, List<Map<String, Object?>>> tables,
  }) : tables = Map.unmodifiable(
         tables.map(
           (key, rows) => MapEntry(
             key,
             List<Map<String, Object?>>.unmodifiable(
               rows.map((row) => Map<String, Object?>.unmodifiable(row)),
             ),
           ),
         ),
       );

  static const format = 'jfz-reader-backup';
  static const version = 1;
  static const maxBytes = 128 * 1024 * 1024;
  static const tableNames = [
    'cached_novels',
    'cached_toc_sections',
    'cached_toc_chapters',
    'reading_progress',
    'bookmarks',
    'app_settings',
    'recent_searches',
    'download_intents',
    'cached_chapter_payloads',
    'offline_chapter_copies',
  ];
  final DateTime createdAt;
  final bool includesContent;
  final Map<String, List<Map<String, Object?>>> tables;
  List<Map<String, Object?>> rows(String name) => tables[name] ?? const [];
  int get novelCount => rows('cached_novels').length;
  int get progressCount => rows('reading_progress').length;
  int get bookmarkCount => rows('bookmarks').length;
  int get chapterCount => rows('offline_chapter_copies').length;
  int get downloadCount => rows('download_intents').length;

  Uint8List encode() {
    final json = utf8.encode(
      jsonEncode({
        'format': format,
        'version': version,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'includesContent': includesContent,
        'tables': tables,
      }),
    );
    if (json.length > maxBytes) {
      throw const BackupException('备份超过 128 MB，请取消包含正文后重试。');
    }
    return Uint8List.fromList(gzip.encode(json));
  }

  static Future<ReaderBackup> readFile(String path) async {
    final file = File(path);
    if (await file.length() > maxBytes) {
      throw const BackupException('文件超过 128 MB，无法导入。');
    }
    final output = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.openRead().transform(gzip.decoder)) {
        if (output.length + chunk.length > maxBytes) {
          throw const BackupException('解压后的备份超过 128 MB，无法导入。');
        }
        output.add(chunk);
      }
      return fromJson(jsonDecode(utf8.decode(output.takeBytes())));
    } on BackupException {
      rethrow;
    } on Object {
      throw const BackupException('无法读取备份，文件可能损坏或不是 JFZ Reader 备份。');
    }
  }

  static ReaderBackup fromJson(Object? data) {
    try {
      final map = data as Map<String, dynamic>;
      if (map['format'] != format) {
        throw const BackupException('这不是 JFZ Reader 备份文件。');
      }
      if (map['version'] != version) {
        throw const BackupException('此备份版本暂不支持，请更新应用后再导入。');
      }
      final createdAt = DateTime.parse(map['createdAt'] as String);
      final include = map['includesContent'] as bool;
      final raw = map['tables'] as Map<String, dynamic>;
      if (raw.length != tableNames.length ||
          raw.keys.any((key) => !tableNames.contains(key))) {
        throw const FormatException('Unknown backup tables');
      }
      var count = 0;
      final tables = <String, List<Map<String, Object?>>>{};
      for (final name in tableNames) {
        final list = raw[name] as List;
        count += list.length;
        if (count > 250000) throw const BackupException('备份记录过多，无法导入。');
        tables[name] = list.map((item) {
          final row = Map<String, Object?>.from(item as Map);
          if (row.values.any((v) => v != null && v is! String && v is! num)) {
            throw const FormatException('Invalid field');
          }
          return row;
        }).toList();
      }
      if (!include &&
          (tables['cached_chapter_payloads']!.isNotEmpty ||
              tables['offline_chapter_copies']!.isNotEmpty)) {
        throw const FormatException('Unexpected content');
      }
      return ReaderBackup(
        createdAt: createdAt,
        includesContent: include,
        tables: tables,
      );
    } on BackupException {
      rethrow;
    } on Object {
      throw const BackupException('备份格式不完整或数据无效，未导入任何记录。');
    }
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ProgressChoice { local, imported }

class ProgressConflict {
  const ProgressConflict({
    required this.novelId,
    required this.title,
    required this.localPosition,
    required this.importedPosition,
    required this.localTime,
    required this.importedTime,
  });
  final String novelId, title, localPosition, importedPosition;
  final DateTime localTime, importedTime;
  ProgressChoice get recommended => importedTime.isAfter(localTime)
      ? ProgressChoice.imported
      : ProgressChoice.local;
}

class BackupPreview {
  BackupPreview({
    required this.backup,
    required this.localFingerprint,
    required List<ProgressConflict> conflicts,
    required this.newNovels,
    required this.newProgress,
    required this.newBookmarks,
    required this.newChapters,
    required this.newDownloads,
  }) : conflicts = List.unmodifiable(conflicts);
  final ReaderBackup backup;
  final String localFingerprint;
  final List<ProgressConflict> conflicts;
  final int newNovels, newProgress, newBookmarks, newChapters, newDownloads;
}

class BackupMergeResult {
  const BackupMergeResult({
    required this.newNovels,
    required this.progressUpdated,
    required this.bookmarksAdded,
    required this.chaptersAdded,
    required this.downloadsAdded,
  });
  final int newNovels,
      progressUpdated,
      bookmarksAdded,
      chaptersAdded,
      downloadsAdded;
}
