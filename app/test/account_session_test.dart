import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/core/account/account_session_controller.dart';
import 'package:jfzreader/core/account/secure_session_store.dart';
import 'package:jfzreader/features/account/account_screen.dart';
import 'package:jfzreader/features/shell/settings_screen.dart';
import 'package:jfzreader/gateway/novelia/novelia_auth_gateway.dart';

void main() {
  group('account session controller', () {
    for (final operation in ['restore', 'accessToken', 'retry']) {
      for (final failure in [
        NoveliaAuthFailureKind.sessionExpired,
        NoveliaAuthFailureKind.network,
      ]) {
        test('$operation ignores an old account refresh $failure', () async {
          final pending = Completer<StoredAccountSession>();
          final store = InMemoryAccountSessionStore(
            _session('alice', expiresIn: const Duration(seconds: 1)),
          );
          final controller = AccountSessionController(
            gateway: _FakeAuthGateway(refreshFuture: pending.future),
            store: store,
          );
          if (operation != 'restore') {
            await controller.login(username: 'alice', password: 'fixture');
          }
          final oldRequest = switch (operation) {
            'restore' => controller.restore(),
            'retry' => controller.retry(),
            _ => controller.accessToken(forceRefresh: true),
          };
          await Future<void>.delayed(Duration.zero);
          await controller.login(username: 'bob', password: 'fixture');
          final newSession = store.value;
          pending.completeError(NoveliaAuthException(failure, 'old request'));
          await oldRequest;

          expect(controller.snapshot.status, AccountSessionStatus.signedIn);
          expect(controller.snapshot.profile?.username, 'bob');
          expect(store.value, same(newSession));
        });
      }
    }

    test('restores by refreshing and persists the rotated session', () async {
      final stored = _session('alice', expiresIn: const Duration(minutes: 1));
      final refreshed = _session('alice', expiresIn: const Duration(hours: 1));
      final store = InMemoryAccountSessionStore(stored);
      final gateway = _FakeAuthGateway(refreshResult: refreshed);
      final controller = AccountSessionController(
        gateway: gateway,
        store: store,
      );

      await controller.restore();

      expect(controller.snapshot.status, AccountSessionStatus.signedIn);
      expect(controller.snapshot.profile?.username, 'alice');
      expect(store.value, same(refreshed));
      expect(gateway.refreshCount, 1);
    });

    test(
      'network failure retains the stored account but not a token',
      () async {
        final stored = _session('alice', expiresIn: const Duration(minutes: 1));
        final store = InMemoryAccountSessionStore(stored);
        final controller = AccountSessionController(
          gateway: _FakeAuthGateway(
            refreshError: const NoveliaAuthException(
              NoveliaAuthFailureKind.network,
              'offline',
            ),
          ),
          store: store,
        );

        await controller.restore();

        expect(controller.snapshot.status, AccountSessionStatus.unavailable);
        expect(controller.snapshot.profile?.username, 'alice');
        expect(store.value, same(stored));
        expect(await controller.accessToken(), isNull);
      },
    );

    test('expired refresh clears secrets but preserves no password', () async {
      final store = InMemoryAccountSessionStore(
        _session('alice', expiresIn: const Duration(minutes: 1)),
      );
      final controller = AccountSessionController(
        gateway: _FakeAuthGateway(
          refreshError: const NoveliaAuthException(
            NoveliaAuthFailureKind.sessionExpired,
            'expired',
          ),
        ),
        store: store,
      );

      await controller.restore();

      expect(controller.snapshot.status, AccountSessionStatus.signedOut);
      expect(store.value, isNull);
    });

    test(
      'a background token network failure retains the signed-in UI',
      () async {
        final store = InMemoryAccountSessionStore();
        final controller = AccountSessionController(
          gateway: _FakeAuthGateway(
            refreshError: const NoveliaAuthException(
              NoveliaAuthFailureKind.network,
              'offline',
            ),
          ),
          store: store,
        );
        await controller.login(username: 'alice', password: 'fixture');
        final stored = store.value;

        expect(await controller.accessToken(forceRefresh: true), isNull);
        expect(controller.snapshot.status, AccountSessionStatus.signedIn);
        expect(store.value, same(stored));
      },
    );

    test('concurrent token requests share one refresh', () async {
      final completer = Completer<StoredAccountSession>();
      final stored = _session('alice', expiresIn: const Duration(seconds: 1));
      final gateway = _FakeAuthGateway(refreshFuture: completer.future);
      final controller = AccountSessionController(
        gateway: gateway,
        store: InMemoryAccountSessionStore(stored),
      );
      final restore = controller.restore();
      await Future<void>.delayed(Duration.zero);
      final token = controller.accessToken();
      completer.complete(
        _session('alice', expiresIn: const Duration(hours: 1)),
      );

      await restore;
      await token;
      expect(gateway.refreshCount, 1);
    });

    test(
      'logout deletes local credentials even if remote logout fails',
      () async {
        final session = _session('alice', expiresIn: const Duration(hours: 1));
        final store = InMemoryAccountSessionStore(session);
        final gateway = _FakeAuthGateway(
          refreshResult: session,
          logoutError: const NoveliaAuthException(
            NoveliaAuthFailureKind.network,
            'offline',
          ),
        );
        final controller = AccountSessionController(
          gateway: gateway,
          store: store,
        );
        await controller.restore();

        await controller.logout();

        expect(store.value, isNull);
        expect(controller.snapshot.status, AccountSessionStatus.signedOut);
      },
    );

    test('logout wins a race with an in-flight refresh', () async {
      final completer = Completer<StoredAccountSession>();
      final stored = _session('alice', expiresIn: const Duration(seconds: 1));
      final store = InMemoryAccountSessionStore(stored);
      final gateway = _FakeAuthGateway(refreshFuture: completer.future);
      final controller = AccountSessionController(
        gateway: gateway,
        store: store,
      );
      final restore = controller.restore();
      await Future<void>.delayed(Duration.zero);

      final logout = controller.logout();
      completer.complete(
        _session('alice', expiresIn: const Duration(hours: 1)),
      );
      await restore;
      await logout;

      expect(store.value, isNull);
      expect(controller.snapshot.status, AccountSessionStatus.signedOut);
    });
  });

  testWidgets('failed local logout stays signed in and can be retried', (
    tester,
  ) async {
    final store = _FailingClearStore();
    final controller = AccountSessionController(
      gateway: _FakeAuthGateway(),
      store: store,
    );
    addTearDown(controller.dispose);
    await controller.login(username: 'alice', password: 'fixture');
    final stored = store.value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, child) => SettingsScreen(
              themeMode: ThemeMode.system,
              onThemeModeChanged: (_) {},
              onClearSearchHistory: () {},
              accountSession: controller.snapshot,
              onAccountLogout: controller.logout,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('account-logout-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-account-logout')));
    await tester.pumpAndSettle();

    expect(find.text('无法清除本机登录信息，请重试退出登录'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(controller.snapshot.status, AccountSessionStatus.signedIn);
    expect(store.value, same(stored));

    store.failClear = false;
    await tester.tap(find.byKey(const ValueKey('account-logout-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-account-logout')));
    await tester.pumpAndSettle();

    expect(find.text('未登录'), findsOneWidget);
    expect(controller.snapshot.status, AccountSessionStatus.signedOut);
    expect(store.value, isNull);
  });

  testWidgets('login form reports a rejected credential without leaving', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AccountScreen(
          onLogin: ({required username, required password}) async {
            throw const NoveliaAuthException(
              NoveliaAuthFailureKind.invalidCredentials,
              'rejected',
            );
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-username-field')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-password-field')),
      'wrong',
    );
    await tester.tap(find.byKey(const ValueKey('account-login-button')));
    await tester.pumpAndSettle();

    expect(find.text('用户名或密码不正确'), findsOneWidget);
    expect(find.byType(AccountScreen), findsOneWidget);
  });

  testWidgets('login form exposes a safe invalid-response diagnostic code', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AccountScreen(
          onLogin: ({required username, required password}) async {
            throw const NoveliaAuthException(
              NoveliaAuthFailureKind.invalidResponse,
              'invalid token',
              diagnosticCode: 'refresh_invalid_access_token',
            );
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-username-field')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-password-field')),
      'secret',
    );
    await tester.tap(find.byKey(const ValueKey('account-login-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('刷新响应不是可识别的访问令牌（refresh_invalid_access_token）'),
      findsOneWidget,
    );
  });
}

class _FailingClearStore extends InMemoryAccountSessionStore {
  bool failClear = true;

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('fixture storage unavailable');
    await super.clear();
  }
}

class _FakeAuthGateway implements NoveliaAuthGateway {
  _FakeAuthGateway({
    this.refreshResult,
    this.refreshFuture,
    this.refreshError,
    this.logoutError,
  });

  final StoredAccountSession? refreshResult;
  final Future<StoredAccountSession>? refreshFuture;
  final NoveliaAuthException? refreshError;
  final NoveliaAuthException? logoutError;
  int refreshCount = 0;

  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) async =>
      refreshResult ?? _session(username, expiresIn: const Duration(hours: 1));

  @override
  Future<void> logout(StoredAccountSession session) async {
    if (logoutError case final error?) throw error;
  }

  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) async {
    refreshCount += 1;
    if (refreshError case final error?) throw error;
    if (refreshFuture case final future?) return future;
    return refreshResult ?? session;
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
