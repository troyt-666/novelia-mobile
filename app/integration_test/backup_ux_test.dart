import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';

import '../test/support/backup_fixture.dart';
import '../test/support/backup_screen_fixture.dart';

/// All data is synthetic and in memory. Never opens the normal reader database.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('backup native fixture flow', (tester) async {
    await binding.convertFlutterSurfaceToImage();
    final local = SqliteOfflineRepository.openInMemory();
    final incoming = SqliteOfflineRepository.openInMemory();
    addTearDown(local.close);
    addTearDown(incoming.close);
    seedBackupNovel(local);
    seedBackupNovel(incoming);
    seedBackupProgress(local, chapter: 'c3');
    seedBackupProgress(
      incoming,
      chapter: 'c1',
      time: backupTime.add(const Duration(hours: 3)),
    );
    seedBackupBookmark(incoming);
    final files = FixtureBackupFiles()..incoming = incoming.exportBackup();
    Future<void> tap(String key) async {
      final scrollable = find.byType(Scrollable).first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        240,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot(name);
    }

    await tester.pumpWidget(backupScreenFixture(local, files));
    await capture('backup-phone');
    await tap('backup-import');
    await capture('backup-phone-preview');
    await tap('backup-choice-$backupNovelId-local');
    await tap('backup-merge');
    await capture('backup-phone-success');
    expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c3');
    expect(local.listBookmarks(), hasLength(2));
    files.failure = const BackupException('文件已损坏，请重新选择备份。');
    await tap('backup-import');
    await capture('backup-phone-error');
    files.failure = null;
    await tester.pumpWidget(
      backupScreenFixture(local, files, dark: true, scale: 1.6),
    );
    await tap('backup-import');
    await tester.drag(
      find.byKey(const ValueKey('backup-scroll')),
      const Offset(0, 1000),
    );
    await capture('backup-phone-dark-large-preview');
    await tap('backup-cancel');
    await tester.pumpWidget(const SizedBox());
  });
}
