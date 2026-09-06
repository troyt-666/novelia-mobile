import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../gateway/novelia/novelia_gateway.dart';
import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_document.dart';

typedef WenkuEpubRootDirectory = Future<Directory> Function();

class WenkuEpubStore {
  const WenkuEpubStore({this.rootDirectory});

  final WenkuEpubRootDirectory? rootDirectory;

  Future<WenkuEpubDocument?> load(WenkuEpubRequest request) async {
    final target = await _fileFor(request);
    if (!await target.exists()) return null;
    try {
      final bytes = await target.readAsBytes();
      try {
        return _parseEpub(bytes);
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
    Uint8List bytes,
  ) async {
    final document = _parseEpub(bytes);
    final target = await _fileFor(request, createDirectory: true);
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    return (file: await temporary.rename(target.path), document: document);
  }

  Future<File> _fileFor(
    WenkuEpubRequest request, {
    bool createDirectory = false,
  }) async {
    final root =
        await (rootDirectory?.call() ?? getApplicationSupportDirectory());
    final directory = Directory(p.join(root.path, 'wenku'));
    if (createDirectory) await directory.create(recursive: true);
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
    final target = File(p.join(directory.path, '$digest.epub'));
    return target;
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
