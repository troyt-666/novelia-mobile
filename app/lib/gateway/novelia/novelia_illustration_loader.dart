import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'novelia_gateway.dart';

abstract interface class NoveliaIllustrationLoader {
  Future<Uint8List> load(Uri uri);
}

/// Downloads the original image bytes, with the same Pixiv referrer as reading.
/// Image hosts never receive the reader's website credentials.
class HttpNoveliaIllustrationLoader implements NoveliaIllustrationLoader {
  const HttpNoveliaIllustrationLoader({
    this.timeout = const Duration(seconds: 20),
    this.maximumBytes = 32 * 1024 * 1024,
  });

  final Duration timeout;
  final int maximumBytes;

  @override
  Future<Uint8List> load(Uri uri) async {
    if (!const ['https', 'http'].contains(uri.scheme) || uri.host.isEmpty) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Invalid illustration URL.',
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      if (uri.host.endsWith('.pximg.net')) {
        request.headers.set(
          HttpHeaders.refererHeader,
          'https://www.pixiv.net/',
        );
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.network,
          'Illustration download failed.',
        );
      }
      if (response.contentLength > maximumBytes) {
        throw const FormatException('Illustration exceeds the size limit.');
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (body.length + chunk.length > maximumBytes) {
          throw const FormatException('Illustration exceeds the size limit.');
        }
        body.add(chunk);
      }
      final bytes = body.takeBytes();
      // A 200 HTML error page or damaged image must not count as downloaded.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1,
        targetHeight: 1,
      );
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      return bytes;
    } on NoveliaGatewayException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.timeout,
        'Illustration download timed out.',
      );
    } on Object {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'Illustration could not be downloaded or decoded.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
