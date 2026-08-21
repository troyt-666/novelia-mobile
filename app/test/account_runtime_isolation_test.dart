import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/core/account/account_session_controller.dart';
import 'package:jfzreader/core/account/account_sync_models.dart';
import 'package:jfzreader/core/account/secure_session_store.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/gateway/novelia/novelia_account_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_auth_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/main.dart';

void main() {
  testWidgets('signed-out restoration clears only account history outbox', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: 'syosetu/n1',
        providerId: 'syosetu',
        serviceNovelId: 'n1',
        chapterId: 'c1',
        occurredAt: DateTime.utc(2026, 8, 18),
      ),
    );
    final controller = AccountSessionController(
      gateway: _UnusedAuthGateway(),
      store: InMemoryAccountSessionStore(),
    );

    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        accountSessionController: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.listRemoteHistoryOutbox(), isEmpty);
  });

  testWidgets('login as another user clears the previous history outbox', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: 'syosetu/n1',
        providerId: 'syosetu',
        serviceNovelId: 'n1',
        chapterId: 'c1',
        occurredAt: DateTime.utc(2026, 8, 18),
      ),
    );
    final history = _RecordingAccountGateway();
    final controller = AccountSessionController(
      gateway: _SwitchableAuthGateway(),
      store: InMemoryAccountSessionStore(
        _session('alice', expiresIn: const Duration(minutes: 1)),
      ),
    );

    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        accountSessionController: controller,
        accountGateway: history,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.snapshot.status, AccountSessionStatus.unavailable);
    expect(repository.listRemoteHistoryOutbox(), isNotEmpty);

    await controller.login(username: 'bob', password: 'secret');
    await tester.pumpAndSettle();

    expect(controller.snapshot.profile?.username, 'bob');
    expect(repository.listRemoteHistoryOutbox(), isEmpty);
    expect(history.historyPuts, isEmpty);
  });

  testWidgets('history flush drains a newer chapter after a stale PUT', (
    tester,
  ) async {
    final repository = SqliteOfflineRepository.openInMemory();
    addTearDown(repository.close);
    repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: 'syosetu/n1',
        providerId: 'syosetu',
        serviceNovelId: 'n1',
        chapterId: 'c1',
        occurredAt: DateTime.utc(2026, 8, 18, 10),
      ),
    );
    final firstPut = Completer<void>();
    final history = _RecordingAccountGateway(blockFirstPut: firstPut);
    final session = _session('alice', expiresIn: const Duration(hours: 1));
    final controller = AccountSessionController(
      gateway: _SwitchableAuthGateway(refreshResult: session),
      store: InMemoryAccountSessionStore(session),
    );

    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repository,
        accountSessionController: controller,
        accountGateway: history,
      ),
    );
    for (
      var attempt = 0;
      attempt < 20 && history.historyPuts.isEmpty;
      attempt++
    ) {
      await tester.pump();
    }
    expect(history.historyPuts, ['c1']);

    repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: 'syosetu/n1',
        providerId: 'syosetu',
        serviceNovelId: 'n1',
        chapterId: 'c2',
        occurredAt: DateTime.utc(2026, 8, 18, 11),
      ),
    );
    firstPut.complete();
    for (
      var attempt = 0;
      attempt < 20 && history.historyPuts.length < 2;
      attempt++
    ) {
      await tester.pump();
    }

    expect(history.historyPuts, ['c1', 'c2']);
    expect(repository.listRemoteHistoryOutbox(), isEmpty);
  });
}

class _UnusedAuthGateway implements NoveliaAuthGateway {
  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<void> logout(StoredAccountSession session) =>
      throw UnimplementedError();

  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) =>
      throw UnimplementedError();
}

class _SwitchableAuthGateway implements NoveliaAuthGateway {
  _SwitchableAuthGateway({this.refreshResult});

  final StoredAccountSession? refreshResult;

  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) async => _session(username, expiresIn: const Duration(hours: 1));

  @override
  Future<void> logout(StoredAccountSession session) async {}

  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) async {
    if (refreshResult case final refreshed?) return refreshed;
    throw const NoveliaAuthException(NoveliaAuthFailureKind.network, 'offline');
  }
}

class _RecordingAccountGateway implements NoveliaAccountGateway {
  _RecordingAccountGateway({this.blockFirstPut});

  final Completer<void>? blockFirstPut;
  final List<String> historyPuts = [];

  @override
  Future<List<RemoteFavoriteFolder>> listFavoriteFolders() async => const [];

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listFavoriteWebNovels({
    required String folderId,
    int page = 0,
    int pageSize = 30,
  }) async => const NoveliaPage(items: [], pageCount: 0);

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listReadHistory({
    int page = 0,
    int pageSize = 30,
  }) async => const NoveliaPage(items: [], pageCount: 0);

  @override
  Future<RemoteFavoriteFolder> createFavoriteFolder(String title) async {
    return RemoteFavoriteFolder(id: title, title: title);
  }

  @override
  Future<void> favoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {}

  @override
  Future<void> unfavoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {}

  @override
  Future<void> updateReadHistory({
    required String providerId,
    required String novelId,
    required String chapterId,
  }) async {
    historyPuts.add(chapterId);
    if (historyPuts.length == 1 && blockFirstPut != null) {
      await blockFirstPut!.future;
    }
  }
}

StoredAccountSession _session(String username, {required Duration expiresIn}) {
  return StoredAccountSession(
    cookieHeader: 'refresh=value',
    accessToken: _token(username, expiresIn: expiresIn),
  );
}

String _token(String username, {required Duration expiresIn}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({'sub': username, 'role': 'member', 'iat': now, 'crat': now - 3600, 'exp': now + expiresIn.inSeconds})}.signature';
}
