import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../gateway/novelia/novelia_gateway.dart';
import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_document.dart';
import '../../core/backup/wenku_backup_entry.dart';
import 'wenku_epub_images.dart';
import '../../gateway/novelia/novelia_illustration_loader.dart';

typedef WenkuEpubRootDirectory = Future<Directory> Function();

class WenkuReadingPosition {
  const WenkuReadingPosition({
    required this.spineIndex,
    required this.fraction,
  });
  final int spineIndex;
  final double fraction;
}

class WenkuDownloadedEpub {
  const WenkuDownloadedEpub({
    required this.fileName,
    required this.title,
    this.volumeId,
    this.order,
    this.byteCount = 0,
    this.missingImages = 0,
  });

  final int byteCount;
  final int missingImages;
  final String fileName;
  final String title;
  final String? volumeId;
  // Older downloads did not retain their language order. Keep their layout.
  final WenkuBilingualOrder? order;
}

class WenkuEpubStore {
  const WenkuEpubStore({
    this.rootDirectory,
    this.illustrationLoader = const HttpNoveliaIllustrationLoader(
      allowSvg: true,
    ),
  });

  // Serialize local commits, never the network fetch. A remove cannot race an
  // archive replacement, including calls made through another store instance.
  static Future<void> _pendingFileWrites = Future<void>.value();
  static Future<T> _writeFiles<T>(Future<T> Function() action) {
    final operation = _pendingFileWrites.then((_) => action());
    _pendingFileWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  final NoveliaIllustrationLoader illustrationLoader;

  final WenkuEpubRootDirectory? rootDirectory;

  Future<WenkuReadingPosition?> readingPosition(String fileName) async {
    try {
      final file = await _positionFile(fileName);
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final spine = value['spineIndex'] as int;
      final fraction = (value['fraction'] as num).toDouble();
      if (spine < 0 || !fraction.isFinite || fraction < 0 || fraction > 1) {
        return null;
      }
      return WenkuReadingPosition(spineIndex: spine, fraction: fraction);
    } on Object {
      // Missing or damaged progress must not prevent opening a local book.
      return null;
    }
  }

  Future<void> saveReadingPosition(
    String fileName,
    WenkuReadingPosition position,
  ) => _writeFiles(() async {
    if (position.spineIndex < 0 ||
        !position.fraction.isFinite ||
        position.fraction < 0 ||
        position.fraction > 1) {
      throw ArgumentError('Invalid EPUB reading position.');
    }
    final file = await _positionFile(fileName);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(
      jsonEncode({
        'spineIndex': position.spineIndex,
        'fraction': position.fraction,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  });

  Future<File> _positionFile(String fileName) async {
    if (p.basename(fileName) != fileName || p.extension(fileName) != '.epub') {
      throw ArgumentError('Invalid EPUB filename.');
    }
    return File(p.join((await _directory()).path, '$fileName.position.json'));
  }

  Future<Directory> _directory() async {
    final root =
        await (rootDirectory?.call() ?? getApplicationSupportDirectory());
    return Directory(p.join(root.path, 'wenku'));
  }

  Future<List<WenkuDownloadedEpub>> listDownloads() async {
    final directory = await _directory();
    if (!await directory.exists()) return const [];
    final downloads = <WenkuDownloadedEpub>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.epub') continue;
      try {
        downloads.add(await _describeDownload(entity));
      } on FileSystemException {
        // One missing file must not hide the remaining downloads.
      } on FormatException {
        // A malformed publication must not hide the other downloads.
      } on NoveliaGatewayException {
        // Leave damaged files in place; only list readable EPUBs.
      }
    }
    downloads.sort((a, b) {
      final title = a.title.compareTo(b.title);
      return title != 0 ? title : a.fileName.compareTo(b.fileName);
    });
    return downloads;
  }

  Future<WenkuDownloadedEpub> _describeDownload(File file) async {
    final fileName = p.basename(file.path);
    final original = await file.stat();
    Future<void> index(WenkuDownloadedEpub download) => _writeFiles(() async {
      final current = await file.stat();
      if (current.type == FileSystemEntityType.file &&
          current.size == original.size &&
          current.modified == original.modified) {
        await _writeMetadata(file, download);
      }
    });
    try {
      final metadata = jsonDecode(
        await File('${file.path}.json').readAsString(),
      );
      if (metadata is Map<String, dynamic> &&
          metadata['title'] is String &&
          (metadata['volumeId'] == null || metadata['volumeId'] is String)) {
        final download = WenkuDownloadedEpub(
          fileName: fileName,
          byteCount: await file.length(),
          missingImages: metadata['missingImages'] is int
              ? metadata['missingImages'] as int
              : (await _imageCountAsync(await file.readAsBytes())),
          title: metadata['title'] as String,
          volumeId: metadata['volumeId'] as String?,
          order: WenkuBilingualOrder.values
              .where((order) => order.name == metadata['order'])
              .firstOrNull,
        );
        if (metadata['missingImages'] is! int) {
          try {
            await index(download);
          } on FileSystemException {
            /* Readable legacy files remain accessible. */
          }
        }
        return download;
      }
    } on FileSystemException {
      // Existing installations have EPUBs without a download index.
    } on FormatException {
      // Recover a damaged index from the EPUB itself.
    }
    final bytes = await file.readAsBytes();
    final document = await _parseAsync(bytes);
    final download = WenkuDownloadedEpub(
      fileName: fileName,
      title: document.title,
      byteCount: bytes.length,
      missingImages: await _imageCountAsync(bytes),
    );
    try {
      await index(download);
    } on FileSystemException {
      // Indexing is optional: a readable old download stays accessible.
    }
    return download;
  }

  Future<WenkuEpubDocument> openDownload(WenkuDownloadedEpub download) async {
    if (p.basename(download.fileName) != download.fileName ||
        p.extension(download.fileName) != '.epub') {
      throw const FormatException('Invalid local EPUB name.');
    }
    final directory = await _directory();
    final bytes = await File(
      p.join(directory.path, download.fileName),
    ).readAsBytes();
    return _parseAsync(bytes);
  }

  Future<void> _writeMetadata(File file, WenkuDownloadedEpub download) async {
    final metadata = File('${file.path}.json');
    final temporary = File('${metadata.path}.part');
    await temporary.writeAsString(
      jsonEncode({
        'title': download.title,
        'volumeId': download.volumeId,
        'order': download.order?.name,
        'missingImages': download.missingImages,
      }),
      flush: true,
    );
    await temporary.rename(metadata.path);
  }

  Future<WenkuEpubDocument?> load(WenkuEpubRequest request) async {
    final target = await _fileFor(request);
    if (!await target.exists()) return null;
    try {
      final bytes = await target.readAsBytes();
      try {
        return await _parseAsync(bytes);
      } on NoveliaGatewayException {
        // Keep the file until a replacement has been downloaded and validated.
        // A concurrent successful save must never be deleted by an older read.
      }
    } on FileSystemException {
      // A stale or concurrently replaced cache entry is a cache miss.
    }
    return null;
  }

  Future<({File file, WenkuEpubDocument document})> save(
    WenkuEpubRequest request,
    Uint8List bytes, {
    String? title,
    void Function()? checkCancelled,
  }) async {
    final images = await _imagesAsync(bytes);
    final packed = images.missingCount == 0
        ? (bytes: bytes, missing: 0)
        : await images.download(
            illustrationLoader,
            checkCancelled: checkCancelled,
          );
    checkCancelled?.call();
    final document = await _parseAsync(packed.bytes);
    return _writeFiles(() async {
      checkCancelled?.call();
      final target = await _fileFor(request, createDirectory: true);
      final temporary = File('${target.path}.part');
      await temporary.writeAsBytes(packed.bytes, flush: true);
      final file = await temporary.rename(target.path);
      await _writeMetadata(
        file,
        WenkuDownloadedEpub(
          fileName: p.basename(file.path),
          title: title ?? document.title,
          volumeId: request.volumeId,
          order: request.order,
          missingImages: packed.missing,
        ),
      );
      return (file: file, document: document);
    });
  }

  Future<void> remove(WenkuDownloadedEpub download) => _writeFiles(() async {
    final file = await _downloadFile(download.fileName);
    // Reading position deliberately survives removing a downloaded file.
    for (final target in [file, File('${file.path}.json')]) {
      if (await target.exists()) await target.delete();
    }
  });

  Future<File> _downloadFile(String fileName) async {
    if (fileName.contains('/') ||
        fileName.contains('\\') ||
        fileName == '.epub' ||
        p.extension(fileName) != '.epub') {
      throw const FormatException('Invalid local EPUB name.');
    }
    return File(p.join((await _directory()).path, fileName));
  }

  /// Repairs an existing archive in place without contacting the account API.
  Future<bool> repairImages(WenkuDownloadedEpub download) async {
    final file = await _downloadFile(download.fileName);
    final original = await file.stat();
    final bytes = await file.readAsBytes();
    final images = await _imagesAsync(bytes);
    final packed = images.missingCount == 0
        ? (bytes: bytes, missing: 0)
        : await images.download(illustrationLoader);
    return _writeFiles(() async {
      final current = await file.stat();
      if (current.type != FileSystemEntityType.file ||
          current.modified != original.modified ||
          current.size != original.size) {
        return false; // A removed or replaced download must never reappear.
      }
      final temporary = File('${file.path}.images.part');
      await temporary.writeAsBytes(packed.bytes, flush: true);
      await temporary.rename(file.path);
      await _writeMetadata(
        file,
        WenkuDownloadedEpub(
          fileName: download.fileName,
          title: download.title,
          volumeId: download.volumeId,
          order: download.order,
          missingImages: packed.missing,
        ),
      );
      return packed.missing == 0;
    });
  }

  Future<List<WenkuBackupEntry>> backupEntries({
    required bool includeContent,
  }) async {
    final downloads = {for (final d in await listDownloads()) d.fileName: d};
    final names = downloads.keys.toSet();
    final directory = await _directory();
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.epub.position.json')) {
          names.add(
            p
                .basename(entity.path)
                .replaceFirst(RegExp(r'\.position\.json$'), ''),
          );
        }
      }
    }
    return [
      for (final name in names)
        await _backupEntry(name, downloads[name], includeContent),
    ];
  }

  Future<WenkuBackupEntry> _backupEntry(
    String name,
    WenkuDownloadedEpub? download,
    bool includeContent,
  ) async {
    final position = await readingPosition(name);
    return WenkuBackupEntry(
      fileName: name,
      title: download?.title ?? name,
      volumeId: download?.volumeId,
      order: download?.order?.name,
      spineIndex: position?.spineIndex,
      fraction: position?.fraction,
      bytes: includeContent && download != null
          ? await (await _downloadFile(name)).readAsBytes()
          : null,
    );
  }

  Future<void> validateBackupEntries(List<WenkuBackupEntry> entries) async {
    if (entries.map((entry) => entry.fileName).toSet().length !=
        entries.length) {
      throw const FormatException('Duplicate EPUB backup records.');
    }
    for (final entry in entries) {
      await _downloadFile(entry.fileName);
      if (entry.bytes != null) {
        final document = await _parseAsync(entry.bytes!);
        if (entry.spineIndex != null &&
            entry.spineIndex! >= document.spineLength) {
          throw const FormatException(
            'EPUB progress points outside its spine.',
          );
        }
      }
    }
  }

  /// Stage every attachment before changing either the filesystem or database.
  /// Existing files and positions win; on a failed DB merge undo only additions.
  Future<T> mergeBackupEntries<T>(
    List<WenkuBackupEntry> entries,
    T Function() mergeDatabase,
  ) async {
    if (entries.isEmpty) return mergeDatabase();
    await validateBackupEntries(entries);
    return _writeFiles(() async {
      final directory = await _directory();
      await directory.create(recursive: true);
      final staging = await directory.createTemp('backup-import-');
      final pending = <(File, File)>[];
      final added = <File>[];
      Future<void> stage(File target, List<int> bytes) async {
        if (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return;
        }
        final source = File(p.join(staging.path, '${pending.length}'));
        await source.writeAsBytes(bytes, flush: true);
        pending.add((source, target));
      }

      try {
        for (final entry in entries) {
          final target = await _downloadFile(entry.fileName);
          if (entry.bytes != null && !await target.exists()) {
            final missing = await _imageCountAsync(entry.bytes!);
            await stage(target, entry.bytes!);
            await stage(
              File('${target.path}.json'),
              utf8.encode(
                jsonEncode({
                  'title': entry.title,
                  'volumeId': entry.volumeId,
                  'order': entry.order,
                  'missingImages': missing,
                }),
              ),
            );
          }
          if (entry.spineIndex != null) {
            await stage(
              await _positionFile(entry.fileName),
              utf8.encode(
                jsonEncode({
                  'spineIndex': entry.spineIndex,
                  'fraction': entry.fraction,
                }),
              ),
            );
          }
        }
        for (final pair in pending) {
          if (await FileSystemEntity.type(pair.$2.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            continue;
          }
          await pair.$1.rename(pair.$2.path);
          added.add(pair.$2);
        }
        return mergeDatabase();
      } on Object {
        for (final file in added.reversed) {
          if (await file.exists()) await file.delete();
        }
        rethrow;
      } finally {
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
        } on FileSystemException {
          /* Cleanup must not turn a committed import into a failure. */
        }
      }
    });
  }

  Future<File> _fileFor(
    WenkuEpubRequest request, {
    bool createDirectory = false,
  }) async {
    final directory = await _directory();
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, fileNameForRequest(request)));
  }

  String fileNameForRequest(WenkuEpubRequest request) {
    final identity = [
      request.novelId,
      request.volumeId,
      request.order.serviceCode,
      ...request.providers.map((provider) => provider.serviceCode),
    ].join('|');
    final digest = sha256
        .convert(identity.codeUnits)
        .toString()
        .substring(0, 20);
    return '$digest.epub';
  }

  // Keep isolate closures separate from file transactions and their callbacks.
  // Capturing a caller's closure context can otherwise send a live DB handle.
  static Future<WenkuEpubDocument> _parseAsync(Uint8List bytes) =>
      Isolate.run(() => _parseEpub(bytes));
  static Future<WenkuEpubImages> _imagesAsync(Uint8List bytes) =>
      Isolate.run(() => WenkuEpubImages(bytes));
  static Future<int> _imageCountAsync(Uint8List bytes) =>
      Isolate.run(() => WenkuEpubImages(bytes).missingCount);

  static WenkuEpubDocument _parseEpub(Uint8List bytes) {
    if (bytes.length < 64 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The downloaded file was not an EPUB archive.',
      );
    }
    return WenkuEpubDocument.parse(bytes);
  }
}
