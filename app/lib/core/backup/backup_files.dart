import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_backup.dart';

abstract interface class BackupFiles {
  Future<ReaderBackup?> open();
  Future<bool> save(ReaderBackup backup);
}

/// System pickers grant access only to the document selected by the user.
/// Native imports return a private temporary copy, never the original document.
class SystemBackupFiles implements BackupFiles {
  const SystemBackupFiles();
  static const _channel = MethodChannel(
    'io.github.troyt666.jfzreader/backup_files',
  );

  @override
  Future<ReaderBackup?> open() async {
    final path = await _channel.invokeMethod<String>('pickBackup');
    if (path == null) return null;
    try {
      return await compute(ReaderBackup.readFile, path);
    } finally {
      try {
        await File(path).delete();
      } on FileSystemException {
        /* Temporary cleanup is best effort. */
      }
    }
  }

  @override
  Future<bool> save(ReaderBackup backup) async {
    final root = await getTemporaryDirectory();
    await root.create(recursive: true);
    final directory = await root.createTemp('jfz-backup-');
    try {
      final stamp = backup.createdAt.toLocal().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final file = File('${directory.path}/JFZ-Reader-$stamp.jfzbackup');
      await file.writeAsBytes(await compute(_encode, backup), flush: true);
      return await _channel.invokeMethod<bool>('saveBackup', file.path) ??
          false;
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Best effort. */
      }
    }
  }

  static Uint8List _encode(ReaderBackup backup) => backup.encode();
}
