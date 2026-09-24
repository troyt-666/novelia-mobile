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
  });

  final String fileName;
  final String title;
  final String? volumeId;
  // Older downloads did not retain their language order. Keep their layout.
  final WenkuBilingualOrder? order;
}

class WenkuEpubStore {
  const WenkuEpubStore({this.rootDirectory});

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
  ) async {
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
  }

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
    try {
      final metadata = jsonDecode(
        await File('${file.path}.json').readAsString(),
      );
      if (metadata is Map<String, dynamic> &&
          metadata['title'] is String &&
          (metadata['volumeId'] == null || metadata['volumeId'] is String)) {
        return WenkuDownloadedEpub(
          fileName: fileName,
          title: metadata['title'] as String,
          volumeId: metadata['volumeId'] as String?,
          order: WenkuBilingualOrder.values
              .where((order) => order.name == metadata['order'])
              .firstOrNull,
        );
      }
    } on FileSystemException {
      // Existing installations have EPUBs without a download index.
    } on FormatException {
      // Recover a damaged index from the EPUB itself.
    }
    final bytes = await file.readAsBytes();
    final document = await Isolate.run(() => _parseEpub(bytes));
    final download = WenkuDownloadedEpub(
      fileName: fileName,
      title: document.title,
    );
    try {
      await _writeMetadata(file, download);
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
    return Isolate.run(() => _parseEpub(bytes));
  }

  Future<void> _writeMetadata(File file, WenkuDownloadedEpub download) async {
    final metadata = File('${file.path}.json');
    final temporary = File('${metadata.path}.part');
    await temporary.writeAsString(
      jsonEncode({
        'title': download.title,
        'volumeId': download.volumeId,
        'order': download.order?.name,
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
        return await Isolate.run(() => _parseEpub(bytes));
      } on NoveliaGatewayException {
        await target.delete();
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
  }) async {
    final document = await Isolate.run(() => _parseEpub(bytes));
    final target = await _fileFor(request, createDirectory: true);
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    final file = await temporary.rename(target.path);
    await _writeMetadata(
      file,
      WenkuDownloadedEpub(
        fileName: p.basename(file.path),
        title: title ?? document.title,
        volumeId: request.volumeId,
        order: request.order,
      ),
    );
    return (file: file, document: document);
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
