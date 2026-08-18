import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_sync_models.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_account_gateway.dart';

void main() {
  test('history outbox keeps newest activity and compare-deletes', () {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    final first = RemoteHistoryOutboxEntry(
      novelId: 'syosetu/n1',
      providerId: 'syosetu',
      serviceNovelId: 'n1',
      chapterId: 'c1',
      occurredAt: DateTime.utc(2026, 8, 18, 10),
    );
    final newer = RemoteHistoryOutboxEntry(
      novelId: 'syosetu/n1',
      providerId: 'syosetu',
      serviceNovelId: 'n1',
      chapterId: 'c2',
      occurredAt: DateTime.utc(2026, 8, 18, 11),
    );

    repository.queueRemoteHistory(newer);
    repository.queueRemoteHistory(first);

    expect(repository.listRemoteHistoryOutbox().single.chapterId, 'c2');
    expect(repository.removeRemoteHistoryIfUnchanged(first), isFalse);
    expect(repository.removeRemoteHistoryIfUnchanged(newer), isTrue);
    expect(repository.listRemoteHistoryOutbox(), isEmpty);
  });

  test(
    'authenticated gateway decodes folders and retries idempotent 401',
    () async {
      final seen = <String>[];
      var favoriteAttempts = 0;
      var unfavoriteAttempts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final subscription = server.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          startsWith('Bearer token-'),
        );
        if (request.method == 'GET' &&
            request.uri.path.endsWith('/user/favored')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'favoredWeb': [
                {'id': 'default', 'title': '默认收藏夹'},
                {'id': 'later', 'title': '以后读'},
              ],
              'favoredWenku': [],
            }),
          );
        } else if (request.method == 'GET' &&
            request.uri.path.endsWith('/user/favored-web/default')) {
          expect(request.uri.queryParameters['page'], '0');
          expect(request.uri.queryParameters['pageSize'], '30');
          expect(request.uri.queryParameters['query'], '');
          expect(
            request.uri.queryParameters['provider'],
            'kakuyomu,syosetu,novelup,hameln,pixiv,alphapolis',
          );
          expect(request.uri.queryParameters['type'], '0');
          expect(request.uri.queryParameters['level'], '1');
          expect(request.uri.queryParameters['translate'], '0');
          expect(request.uri.queryParameters['sort'], 'update');
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_novelPage('favorite-novel')));
        } else if (request.method == 'GET' &&
            request.uri.path.endsWith('/user/read-history')) {
          expect(request.uri.queryParameters['page'], '1');
          expect(request.uri.queryParameters['pageSize'], '30');
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_novelPage('history-novel')));
        } else if (request.method == 'POST' &&
            request.uri.path.endsWith('/user/favored-web')) {
          expect(
            request.headers.value(HttpHeaders.contentTypeHeader),
            'application/json',
          );
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['title'], '短篇');
          request.response.write('created');
        } else if (request.method == 'PUT' &&
            request.uri.path.contains('/user/favored-web/')) {
          favoriteAttempts += 1;
          if (favoriteAttempts == 1) request.response.statusCode = 401;
        } else if (request.method == 'DELETE' &&
            request.uri.path.contains('/user/favored-web/')) {
          unfavoriteAttempts += 1;
        } else if (request.method == 'PUT' &&
            request.uri.path.endsWith('/user/read-history/syosetu/n1')) {
          expect(request.headers.value(HttpHeaders.contentTypeHeader), isNull);
          expect(await utf8.decoder.bind(request).join(), 'c2');
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      var forceRefreshes = 0;
      final gateway = HttpNoveliaAccountGateway(
        baseUri: Uri.parse(
          'http://${server.address.address}:${server.port}/api/',
        ),
        accessTokenProvider: ({bool forceRefresh = false}) async {
          if (forceRefresh) forceRefreshes += 1;
          return forceRefresh ? 'token-new' : 'token-old';
        },
      );
      addTearDown(gateway.close);

      final folders = await gateway.listFavoriteFolders();
      final favorites = await gateway.listFavoriteWebNovels(
        folderId: 'default',
      );
      final history = await gateway.listReadHistory(page: 1);
      final created = await gateway.createFavoriteFolder(' 短篇 ');
      await gateway.favoriteWebNovel(
        folderId: folders.first.id,
        providerId: 'syosetu',
        novelId: 'n1',
      );
      await gateway.unfavoriteWebNovel(
        folderId: folders.first.id,
        providerId: 'syosetu',
        novelId: 'n1',
      );
      await gateway.updateReadHistory(
        providerId: 'syosetu',
        novelId: 'n1',
        chapterId: 'c2',
      );

      expect(folders.map((folder) => folder.title), ['默认收藏夹', '以后读']);
      expect(favorites.items.single.key.novelId, 'favorite-novel');
      expect(history.items.single.key.novelId, 'history-novel');
      expect(history.pageCount, 2);
      expect(created.id, 'created');
      expect(forceRefreshes, 1);
      expect(favoriteAttempts, 2);
      expect(unfavoriteAttempts, 1);
      expect(seen, contains('PUT /api/user/read-history/syosetu/n1'));
      expect(seen, contains('DELETE /api/user/favored-web/default/syosetu/n1'));
      expect(seen, contains('GET /api/user/favored-web/default'));
      expect(seen, contains('GET /api/user/read-history'));
    },
  );
}

Map<String, Object?> _novelPage(String novelId) => {
  'items': [
    {
      'providerId': 'syosetu',
      'novelId': novelId,
      'titleJp': '題名',
      'titleZh': '题名',
      'type': '连载中',
      'extra': null,
      'attentions': <String>[],
      'keywords': <String>[],
      'total': 2,
      'jp': 2,
      'baidu': 0,
      'youdao': 2,
      'gpt': 0,
      'sakura': 2,
      'updateAt': 1787011200,
    },
  ],
  'pageNumber': 2,
};
