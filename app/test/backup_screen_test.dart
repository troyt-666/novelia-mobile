import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';

import 'support/backup_fixture.dart';
import 'support/backup_screen_fixture.dart';

void main() {
  late SqliteOfflineRepository local, incoming;
  late FixtureBackupFiles files;
  setUp(() {
    local = SqliteOfflineRepository.openInMemory();
    incoming = SqliteOfflineRepository.openInMemory();
    files = FixtureBackupFiles();
    seedBackupNovel(local);
    seedBackupNovel(incoming);
    seedBackupProgress(local, chapter: 'c3');
    seedBackupProgress(
      incoming,
      chapter: 'c1',
      time: backupTime.add(const Duration(hours: 3)),
    );
    files.incoming = incoming.exportBackup();
  });
  tearDown(() {
    local.close();
    incoming.close();
  });
  Future<void> tap(WidgetTester tester, String key) async {
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

  testWidgets('export defaults to records and content is opt in', (
    tester,
  ) async {
    await tester.pumpWidget(backupScreenFixture(local, files));
    await tap(tester, 'backup-export');
    expect(files.exported!.includesContent, isFalse);
    await tap(tester, 'backup-include-content');
    await tap(tester, 'backup-export');
    expect(files.exported!.includesContent, isTrue);
    expect(find.text('备份已保存'), findsOneWidget);
  });
  testWidgets(
    'cancel never writes; explicit conflict choice retains local and bookmarks other',
    (tester) async {
      var imports = 0;
      await tester.pumpWidget(
        backupScreenFixture(local, files, onImported: () => imports++),
      );
      await tap(tester, 'backup-import');
      expect(find.text('导入预览'), findsOneWidget);
      expect(local.listBookmarks(), isEmpty);
      await tap(tester, 'backup-cancel');
      expect(local.listBookmarks(), isEmpty);
      await tap(tester, 'backup-import');
      await tap(tester, 'backup-choice-$backupNovelId-local');
      await tap(tester, 'backup-merge');
      expect(imports, 1);
      expect(local.readingProgressFor(backupNovelId)!.position.chapterId, 'c3');
      expect(local.listBookmarks().single.position.chapterId, 'c1');
    },
  );
  testWidgets('picker cancel and corrupt file leave usable import control', (
    tester,
  ) async {
    files.incoming = null;
    await tester.pumpWidget(backupScreenFixture(local, files));
    await tap(tester, 'backup-import');
    expect(find.text('备份与恢复'), findsOneWidget);
    files.failure = const BackupException('文件已损坏');
    await tap(tester, 'backup-import');
    expect(find.text('文件已损坏'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('backup-import')))
          .onPressed,
      isNotNull,
    );
    expect(local.listBookmarks(), isEmpty);
  });
  testWidgets('stale data keeps preview with refresh action', (tester) async {
    await tester.pumpWidget(backupScreenFixture(local, files));
    await tap(tester, 'backup-import');
    seedBackupBookmark(local);
    await tap(tester, 'backup-merge');
    expect(find.text('导入预览'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新预览'));
    await tester.pumpAndSettle();
    await tap(tester, 'backup-merge');
    expect(find.text('备份与恢复'), findsOneWidget);
  });
  testWidgets('narrow display, long titles and large text remain scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seedBackupNovel(incoming, title: '这是一本名字很长的测试小说，用于检查导入时书名、日期和两个位置能否完整显示');
    files.incoming = incoming.exportBackup();
    await tester.pumpWidget(
      backupScreenFixture(local, files, dark: true, scale: 2),
    );
    await tap(tester, 'backup-import');
    await tap(tester, 'backup-choice-$backupNovelId-local');
    await tap(tester, 'backup-merge');
    expect(tester.takeException(), isNull);
  });
}
