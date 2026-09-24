import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/core/account/account_session_controller.dart';
import 'package:jfzreader/core/account/secure_session_store.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/features/reader/reader_screen.dart';
import 'package:jfzreader/features/shell/download_management_screen.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';
import 'package:jfzreader/gateway/novelia/novelia_auth_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/main.dart';

import 'support/offline_library_fixture.dart';

void main() => runOfflineLibraryStartupTests();

void runOfflineLibraryStartupTests({
  bool useDeviceViewport = false,
  Future<void> Function(WidgetTester tester, String name)? capture,
}) {
  testWidgets(
    'offline cold start retains all downloads, recent reads and bookmarks across account states',
    (tester) async {
      if (!useDeviceViewport) {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final directory = Directory.systemTemp.createTempSync('offline-library-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/reader.sqlite3';
      var repository = SqliteOfflineRepository.openFile(path);
      seedOfflineLibrary(repository);
      repository.close();
      repository = SqliteOfflineRepository.openFile(path);
      addTearDown(repository.close);
      final gateway = OfflineLibraryGateway();
      final auth = _OfflineAuth();
      final controller = AccountSessionController(
        gateway: auth,
        store: InMemoryAccountSessionStore(_session('reader')),
      );
      addTearDown(controller.dispose);
      final content = LiveFirstNoveliaContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        canAccessRestrictedContent: () => controller.snapshot.isSignedIn,
      );
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: content,
          accountSessionController: controller,
        ),
      );
      // The account spinner intentionally keeps animating while refresh is
      // blocked. Local pages must already be usable before it completes.
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (useDeviceViewport) {
        debugPrint('Offline fixture: initial frames ready');
      }

      NoveliaShell shell() =>
          tester.widget<NoveliaShell>(find.byType(NoveliaShell));
      void expectCompleteShelf() {
        expect(shell().continuedReads, hasLength(43));
        expect(shell().protectedDownloads, hasLength(42));
        expect(shell().bookmarks, hasLength(43));
        expect(shell().storageSummary.offlineDownloadChapterCount, 84);
        for (final row in shell().continuedReads) {
          expect(row.position.chapterId, offlineLatestPosition.chapterId);
          expect(row.position.blockId, offlineLatestPosition.blockId);
        }
        expect(repository.novelDetail('syosetu/offline-42'), isNotNull);
        expect(
          repository.chapterPayload(
            novelId: 'syosetu/offline-42',
            chapterId: 'c2',
          ),
          isNotNull,
        );
      }

      // Even an indefinitely pending refresh must not gate local reading.
      expect(controller.snapshot.status, AccountSessionStatus.restoring);
      expectCompleteShelf();
      auth.refreshResult.completeError(
        const NoveliaAuthException(
          NoveliaAuthFailureKind.network,
          'Fixture offline',
        ),
      );
      if (useDeviceViewport) debugPrint('Offline fixture: refresh failed');
      await tester.pumpAndSettle();
      if (useDeviceViewport) debugPrint('Offline fixture: local shelf ready');
      expect(controller.snapshot.status, AccountSessionStatus.unavailable);
      expectCompleteShelf();
      await capture?.call(tester, 'offline-continue');

      await tester.tap(find.byKey(const ValueKey('library-tab-downloads')));
      await tester.pumpAndSettle();
      await capture?.call(tester, 'offline-42-downloads');
      final latest = shell().protectedDownloads.first;
      expect(latest.novel.id, offlineLatestNovelId);
      await tester.tap(
        find.byKey(ValueKey('offline-download-${latest.groupKey}')),
      );
      await tester.pumpAndSettle();
      final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
      expect(reader.initialPosition?.chapterId, 'c2');
      expect(reader.initialPosition?.blockId, 'c2:1');
      expect(gateway.contentRequests, 0);
      await capture?.call(tester, 'offline-downloaded-reader');
      await tester.tap(find.byKey(const ValueKey('reader-back-button')));
      await tester.pumpAndSettle();

      await controller.logout();
      await tester.pumpAndSettle();
      expectCompleteShelf();
      final signedOutRead = await shell().downloadReaderLaunchLoader!(latest);
      expect(signedOutRead.novel.chapters, isNotEmpty);
      await controller.login(username: 'another-reader', password: 'fixture');
      await tester.pumpAndSettle();
      expectCompleteShelf();

      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      final storage = find.byKey(const ValueKey('settings-offline-storage'));
      await tester.ensureVisible(storage);
      await tester.tap(storage);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DownloadManagementScreen>(
              find.byType(DownloadManagementScreen),
            )
            .downloads,
        hasLength(42),
      );
      await capture?.call(tester, 'offline-download-management');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'interrupted offline reader restores from local shelf without a catalog match or account',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('offline-reader-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/reader.sqlite3';
      var repository = SqliteOfflineRepository.openFile(path);
      seedOfflineLibrary(repository);
      repository.saveLastRoute(
        LastRouteState(
          routeName: '/reader',
          novelId: offlineLatestNovelId,
          position: offlineLatestPosition,
          updatedAt: DateTime.utc(2026, 9, 24),
        ),
      );
      repository.close();
      repository = SqliteOfflineRepository.openFile(path);
      addTearDown(repository.close);
      final gateway = OfflineLibraryGateway();
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: LiveFirstNoveliaContentCoordinator(
            gateway: gateway,
            contentRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
      expect(reader.novel.id, offlineLatestNovelId);
      expect(reader.initialPosition?.chapterId, 'c2');
      expect(reader.initialPosition?.blockId, 'c2:1');
      expect(gateway.contentRequests, 0);
      await capture?.call(tester, 'offline-restarted-reader');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

class _OfflineAuth implements NoveliaAuthGateway {
  final refreshResult = Completer<StoredAccountSession>();
  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) =>
      refreshResult.future;
  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) async => _session(username);
  @override
  Future<void> logout(StoredAccountSession session) async {}
}

StoredAccountSession _session(String username) {
  final claims = base64Url
      .encode(
        utf8.encode(jsonEncode({'sub': username, 'role': 'member', 'exp': 1})),
      )
      .replaceAll('=', '');
  return StoredAccountSession(
    cookieHeader: 'fixture=offline',
    accessToken: 'header.$claims.signature',
  );
}
