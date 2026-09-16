import 'dart:async';
import 'package:flutter/material.dart';
import 'package:jfzreader/core/backup/backup_files.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';

import '../test/support/backup_fixture.dart';
import '../test/support/backup_screen_fixture.dart';

/// Manual native picker verification. No persistent reader DB or account store.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.ensureSemantics();
  final repo = SqliteOfflineRepository.openInMemory();
  seedBackupNovel(repo);
  seedBackupProgress(repo);
  seedBackupBookmark(repo);
  seedBackupDownload(repo);
  runApp(backupScreenFixture(repo, const SystemBackupFiles()));
  if (const bool.fromEnvironment('BACKUP_PICKER_TEST')) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkPicker(repo)),
    );
  }
}

Future<void> _checkPicker(SqliteOfflineRepository repo) async {
  const files = SystemBackupFiles();
  final saved = await files.save(repo.exportBackup(includeContent: true));
  if (!saved) throw StateError('Fixture export was cancelled');
  final loaded = await files.open();
  if (loaded == null ||
      loaded.progressCount != 1 ||
      loaded.bookmarkCount != 1 ||
      loaded.chapterCount != 1) {
    throw StateError('Fixture backup roundtrip failed');
  }
  final target = SqliteOfflineRepository.openInMemory();
  try {
    final merged = target.mergeBackup(target.previewBackup(loaded));
    if (merged.progressUpdated != 1 ||
        merged.bookmarksAdded != 1 ||
        merged.chaptersAdded != 1) {
      throw StateError('Fixture merge failed');
    }
    debugPrint('BACKUP_PICKER_ROUNDTRIP_OK: progress=1 bookmarks=1 chapters=1');
  } finally {
    target.close();
  }
}
