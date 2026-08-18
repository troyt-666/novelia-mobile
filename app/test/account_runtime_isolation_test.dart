import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/account/account_models.dart';
import 'package:novelia_reader/core/account/account_session_controller.dart';
import 'package:novelia_reader/core/account/account_sync_models.dart';
import 'package:novelia_reader/core/account/secure_session_store.dart';
import 'package:novelia_reader/core/database/sqlite_offline_repository.dart';
import 'package:novelia_reader/gateway/novelia/novelia_auth_gateway.dart';
import 'package:novelia_reader/main.dart';

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
