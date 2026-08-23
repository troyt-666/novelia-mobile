import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_wenku_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  const codec = WenkuJsonCodec();

  test('decodes Wenku catalog and translation coverage independently', () {
    final page = codec.decodeNovelPage({
      'items': [
        {
          'id': 'novel-1',
          'title': '夜の列車',
          'titleZh': '夜行列车',
          'cover': 'https://example.invalid/cover.jpg',
        },
      ],
      'pageNumber': 4,
    });
    final details = codec.decodeNovel('novel-1', {
      'title': '夜の列車',
      'titleZh': '夜行列车',
      'cover': null,
      'authors': ['作者'],
      'artists': ['画师'],
      'keywords': ['铁路'],
      'publisher': '出版社',
      'imprint': null,
      'level': '一般向',
      'introduction': '简介',
      'volumes': [
        {
          'asin': 'B0001',
          'title': '第一卷',
          'titleZh': null,
          'cover': 'https://example.invalid/v1.jpg',
          'publishAt': 1_787_000_000,
        },
      ],
      'volumeZh': ['第一卷.zh.epub'],
      'volumeJp': [
        {
          'volumeId': '第一卷.epub',
          'total': 100,
          'baidu': 0,
          'youdao': 70,
          'gpt': 90,
          'sakura': 100,
        },
      ],
    });

    expect(page.pageCount, 4);
    expect(page.items.single.id, 'novel-1');
    expect(
      details.japaneseEpubs.single.coverageRatioFor(
        WenkuTranslationProvider.gpt,
      ),
      0.9,
    );
    expect(details.japaneseEpubs.single.availableProviders, [
      WenkuTranslationProvider.sakura,
      WenkuTranslationProvider.gpt,
      WenkuTranslationProvider.youdao,
    ]);
  });

  test('rejects non-HTTPS remote cover locations', () {
    final page = codec.decodeNovelPage({
      'items': [
        {
          'id': 'novel-1',
          'title': '原題',
          'titleZh': '译名',
          'cover': 'http://example.invalid/cover.jpg',
        },
      ],
      'pageNumber': 1,
    });

    expect(page.items.single.coverUri, isNull);
  });

  test('downloads through exactly one pinned Wenku redirect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Uri>[];
    final served = Completer<void>();
    unawaited(() async {
      await for (final request in server) {
        requests.add(request.uri);
        if (request.uri.path == '/api/wenku/novel-1/file/volume.epub') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/files-temp/wenku/generated.epub',
          );
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.add([
            0x50,
            0x4b,
            0x03,
            0x04,
            ...'mimetype'.codeUnits,
          ]);
          await request.response.close();
          served.complete();
          break;
        }
      }
    }());
    final gateway = HttpNoveliaWenkuGateway(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
    );
    addTearDown(gateway.close);

    final bytes = await gateway.downloadEpub(
      const WenkuEpubRequest(
        novelId: 'novel-1',
        volumeId: 'volume.epub',
        order: WenkuBilingualOrder.japaneseFirst,
        providers: [
          WenkuTranslationProvider.sakura,
          WenkuTranslationProvider.gpt,
        ],
        filename: 'volume.epub',
      ),
    );
    await served.future;

    expect(bytes, isA<Uint8List>());
    expect(requests, hasLength(2));
    expect(requests.first.queryParameters['mode'], 'jp-zh');
    expect(requests.first.queryParametersAll['translations'], [
      'sakura',
      'gpt',
    ]);
    expect(requests.last.path, '/files-temp/wenku/generated.epub');
  });

  test('refuses an EPUB redirect outside the generated Wenku path', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      final request = await server.first;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        '/other/file.epub',
      );
      await request.response.close();
    }());
    final gateway = HttpNoveliaWenkuGateway(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
    );
    addTearDown(gateway.close);

    expect(
      gateway.downloadEpub(
        const WenkuEpubRequest(
          novelId: 'novel-1',
          volumeId: 'volume.epub',
          order: WenkuBilingualOrder.chineseFirst,
          providers: [WenkuTranslationProvider.sakura],
          filename: 'volume.epub',
        ),
      ),
      throwsA(
        isA<NoveliaGatewayException>().having(
          (error) => error.kind,
          'kind',
          NoveliaGatewayFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('stops an in-flight EPUB response when cancelled', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final request in server) {
        if (request.uri.path == '/api/wenku/novel-1/file/volume.epub') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/files-temp/wenku/generated.epub',
          );
          await request.response.close();
          continue;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.add(List<int>.filled(4096, 1));
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 1));
        await request.response.close();
        break;
      }
    }());
    final gateway = HttpNoveliaWenkuGateway(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
    );
    addTearDown(gateway.close);
    final cancellation = WenkuEpubDownloadCancellationToken();

    final download = gateway.downloadEpub(
      const WenkuEpubRequest(
        novelId: 'novel-1',
        volumeId: 'volume.epub',
        order: WenkuBilingualOrder.chineseFirst,
        providers: [WenkuTranslationProvider.sakura],
        filename: 'volume.epub',
      ),
      cancellationToken: cancellation,
      onReceiveProgress: (_, _) => cancellation.cancel(),
    );

    await expectLater(
      download,
      throwsA(isA<WenkuEpubDownloadCancelledException>()),
    );
  });
}
