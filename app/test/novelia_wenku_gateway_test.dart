import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_wenku_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  const codec = WenkuJsonCodec();

  test('encodes every upstream Wenku catalog level', () {
    expect(
      [
        for (final level in WenkuCatalogLevel.values)
          WenkuCatalogQuery(level: level).toQueryParameters()['level'],
      ],
      ['0', '1', '2', '3', '4', '5', '6'],
    );
    expect(
      [for (final level in WenkuCatalogLevel.values) level.label],
      ['全部小说', '轻小说', '轻文学', '文学', '非小说', 'R18男性向', 'R18女性向'],
    );
  });

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

  test('both R18 filters use the current session on every page', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <({Uri uri, String? authorization})>[];
    final subscription = server.listen((request) async {
      requests.add((
        uri: request.uri,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"items":[],"pageNumber":2}');
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    String? token = 'fixture-session-one';
    final gateway = HttpNoveliaWenkuGateway(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
      accessTokenProvider: ({bool forceRefresh = false}) => token,
    );
    addTearDown(gateway.close);
    for (final level in [
      WenkuCatalogLevel.r18Male,
      WenkuCatalogLevel.r18Female,
    ]) {
      for (var page = 0; page < 2; page++) {
        await gateway.listNovels(
          WenkuCatalogQuery(level: level, page: page, search: '虚构书名'),
        );
      }
    }
    token = 'fixture-session-two';
    await gateway.listComments('fixture-novel');
    token = null;
    await gateway.listNovels(const WenkuCatalogQuery());

    expect(
      requests.take(4).map((request) => request.authorization),
      everyElement('Bearer fixture-session-one'),
    );
    expect(
      requests.take(4).map((request) => request.uri.queryParameters['level']),
      ['5', '5', '6', '6'],
    );
    expect(
      requests.take(4).map((request) => request.uri.queryParameters['page']),
      ['0', '1', '0', '1'],
    );
    expect(
      requests.take(4).map((request) => request.uri.queryParameters['query']),
      everyElement('虚构书名'),
    );
    expect(requests[4].authorization, 'Bearer fixture-session-two');
    expect(requests.last.authorization, isNull);
  });

  test(
    'refreshes an expired Wenku session and retries the identical query once',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Uri>[];
      final authorization = <String?>[];
      final refreshes = <bool>[];
      final subscription = server.listen((request) async {
        requests.add(request.uri);
        authorization.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        if (authorization.last == 'Bearer fixture-refreshed') {
          request.response.write('{"items":[],"pageNumber":1}');
        } else {
          request.response.statusCode = HttpStatus.unauthorized;
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final gateway = HttpNoveliaWenkuGateway(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
        accessTokenProvider: ({bool forceRefresh = false}) {
          refreshes.add(forceRefresh);
          return forceRefresh ? 'fixture-refreshed' : 'fixture-expired';
        },
      );
      addTearDown(gateway.close);
      await gateway.listNovels(
        const WenkuCatalogQuery(
          level: WenkuCatalogLevel.r18Female,
          page: 1,
          search: '虚构书名',
        ),
      );
      expect(requests, hasLength(2));
      expect(requests.first, requests.last);
      expect(authorization, [
        'Bearer fixture-expired',
        'Bearer fixture-refreshed',
      ]);
      expect(refreshes, [false, true]);
    },
  );

  for (final scenario in [
    (
      status: 401,
      token: null,
      refreshed: null,
      count: 1,
      kind: NoveliaGatewayFailureKind.authenticationRequired,
    ),
    (
      status: 401,
      token: 'fixture-session',
      refreshed: 'fixture-refreshed',
      count: 2,
      kind: NoveliaGatewayFailureKind.authenticationRequired,
    ),
    (
      status: 401,
      token: 'fixture-session',
      refreshed: null,
      count: 1,
      kind: NoveliaGatewayFailureKind.authenticationRequired,
    ),
    (
      status: 403,
      token: 'fixture-session',
      refreshed: 'fixture-refreshed',
      count: 1,
      kind: NoveliaGatewayFailureKind.forbidden,
    ),
  ]) {
    test(
      'reports Wenku access failure without repeated refresh: $scenario',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;
        final refreshes = <bool>[];
        final subscription = server.listen((request) async {
          requests++;
          request.response.statusCode = scenario.status;
          await request.response.close();
        });
        addTearDown(subscription.cancel);
        final gateway = HttpNoveliaWenkuGateway(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
          accessTokenProvider: ({bool forceRefresh = false}) {
            refreshes.add(forceRefresh);
            return forceRefresh ? scenario.refreshed : scenario.token;
          },
        );
        addTearDown(gateway.close);
        await expectLater(
          gateway.getNovel('fixture-restricted'),
          throwsA(
            isA<NoveliaGatewayException>()
                .having((error) => error.kind, 'kind', scenario.kind)
                .having(
                  (error) => error.statusCode,
                  'statusCode',
                  scenario.status,
                ),
          ),
        );
        expect(requests, scenario.count);
        expect(
          refreshes.where((refresh) => refresh).length,
          scenario.status == 401 && scenario.token != null ? 1 : 0,
        );
      },
    );
  }

  test(
    'Wenku comments use the shared endpoint with a Wenku site and zero-based pages',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Uri>[];
      final subscription = server.listen((request) async {
        requests.add(request.uri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'pageNumber': 3,
            'items': [
              {
                'id': 'fixture-comment',
                'user': {'username': '虚构读者'},
                'content': '虚构评论',
                'createAt': 1789689600,
                'replies': [
                  {
                    'id': 'fixture-reply',
                    'user': {'username': '虚构回复者'},
                    'content': '',
                    'hidden': true,
                    'createAt': 1789689601,
                  },
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final gateway = HttpNoveliaWenkuGateway(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
      );
      addTearDown(gateway.close);
      final first = await gateway.listComments('fixture-wenku');
      await gateway.listComments('fixture-wenku', page: 1, pageSize: 5);
      expect(requests.map((uri) => uri.path), ['/api/comment', '/api/comment']);
      expect(requests.first.queryParameters, {
        'site': 'wenku-fixture-wenku',
        'page': '0',
        'pageSize': '10',
      });
      expect(requests.last.queryParameters, {
        'site': 'wenku-fixture-wenku',
        'page': '1',
        'pageSize': '5',
      });
      expect(first.pageCount, 3);
      expect(first.items.single.content, '虚构评论');
      expect(first.items.single.replies.single.hidden, isTrue);
    },
  );

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
