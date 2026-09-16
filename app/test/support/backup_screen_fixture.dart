import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:jfzreader/core/backup/backup_files.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/features/backup/backup_screen.dart';

class FixtureBackupFiles implements BackupFiles {
  ReaderBackup? incoming;
  ReaderBackup? exported;
  Object? failure;
  bool saved = true;
  @override
  Future<ReaderBackup?> open() async {
    if (failure != null) throw failure!;
    return incoming;
  }

  @override
  Future<bool> save(ReaderBackup backup) async {
    exported = backup;
    return saved;
  }
}

Widget backupScreenFixture(
  SqliteOfflineRepository repo,
  BackupFiles files, {
  bool dark = false,
  double scale = 1,
  VoidCallback? onImported,
}) => MaterialApp(
  locale: const Locale('zh', 'CN'),
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: dark ? const Color(0xff78B99A) : const Color(0xff397B62),
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC'],
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: BackupScreen(
    repository: repo,
    files: files,
    onImported: onImported ?? () {},
  ),
);
